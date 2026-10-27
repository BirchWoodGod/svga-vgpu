/*
 * w7xum9.dll: D3D9 user-mode display driver shim.
 *
 * Registered in place of the real D3D9 UMD (UserModeDriverNameWow), it loads
 * the real driver and forwards everything, adding support for the vendor
 * "NULL" render-target format (FOURCC 'NULL') that many D3D9 games use for
 * depth-only passes. VMware's SVGA driver does not expose it, so e.g. Halo
 * Online crashes when CreateTexture(D3DFMT_NULL, RENDERTARGET) fails.
 *
 *  - GetCaps(GETFORMATCOUNT/GETFORMATDATA): append a NULL entry, copied from a
 *    small render-target format the driver supports (R5G6B5, else X8R8G8B8).
 *  - CreateResource(Format = NULL): create the resource with that format.
 *
 * The real driver is named by HKLM\SOFTWARE\win7ext\umdshim "Target9"
 * (64-bit registry view), written by install.ps1; default vm3dum.dll.
 * Log: C:\ProgramData\win7ext\umdshim.log
 */
#include "ddi.h"

/* --- Win32 imports (kernel32, advapi32) --------------------------------- */
typedef void *HMODULE;
typedef void *HKEY;
typedef void *(__stdcall *FARPROC)(void);
#define DECL __declspec(dllimport) __stdcall
DECL HMODULE LoadLibraryW(const WCHAR *);
DECL FARPROC GetProcAddress(HMODULE, const char *);
DECL UINT GetSystemDirectoryW(WCHAR *, UINT);
DECL HANDLE CreateFileW(const WCHAR *, UINT, UINT, void *, UINT, UINT, HANDLE);
DECL int WriteFile(HANDLE, const void *, UINT, UINT *, void *);
DECL int CloseHandle(HANDLE);
DECL int CreateDirectoryW(const WCHAR *, void *);
DECL UINT GetCurrentProcessId(void);
DECL UINT GetModuleFileNameW(HMODULE, WCHAR *, UINT);
DECL long RegOpenKeyExW(HKEY, const WCHAR *, UINT, UINT, HKEY *);
DECL long RegQueryValueExW(HKEY, const WCHAR *, UINT *, UINT *, void *, UINT *);
DECL long RegCloseKey(HKEY);
typedef struct {
	UINT dwLength, dwMemoryLoad;
	unsigned long long TotalPhys, AvailPhys, TotalPageFile, AvailPageFile;
	unsigned long long TotalVirtual, AvailVirtual, AvailExtendedVirtual;
} MEMSTAT;
DECL int GlobalMemoryStatusEx(MEMSTAT *);

#define HKEY_LOCAL_MACHINE ((HKEY)(unsigned long)0x80000002)
#define KEY_QUERY_VALUE 0x0001
#define KEY_WOW64_64KEY 0x0100
#define FILE_APPEND_DATA 0x0004
#define FILE_SHARE_READ_WRITE 0x0003
#define OPEN_ALWAYS 4
#define INVALID_HANDLE ((HANDLE)(long)-1)

/* Freestanding build: the compiler may still emit calls to these. */
void *memcpy(void *d, const void *s, unsigned n)
{
	unsigned char *dd = d;
	const unsigned char *ss = s;
	while (n--)
		*dd++ = *ss++;
	return d;
}

void *memset(void *d, int c, unsigned n)
{
	unsigned char *dd = d;
	while (n--)
		*dd++ = (unsigned char)c;
	return d;
}

/* --- Logging ------------------------------------------------------------ */
static int g_log_budget = 2000;

static void log_write(const char *s, UINT n)
{
	static const WCHAR dir[] = L"C:\\ProgramData\\win7ext";
	static const WCHAR path[] = L"C:\\ProgramData\\win7ext\\umdshim.log";
	HANDLE f;
	UINT done;

	CreateDirectoryW(dir, 0);
	f = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ_WRITE, 0, OPEN_ALWAYS, 0, 0);
	if (f == INVALID_HANDLE)
		return;
	WriteFile(f, s, n, &done, 0);
	CloseHandle(f);
}

/* Tiny printf: %s (char*), %S (WCHAR*, ASCII only), %x (hex), %u (decimal). */
static void shimlog(const char *fmt, ...)
{
	char buf[512];
	UINT n = 0;
	__builtin_va_list ap;

	if (g_log_budget <= 0)
		return;
	g_log_budget--;

	__builtin_va_start(ap, fmt);
	for (const char *p = "[pid "; *p; p++)
		buf[n++] = *p;
	{
		UINT v = GetCurrentProcessId(), d = 1000000000;
		int started = 0;
		for (; d; d /= 10) {
			UINT q = v / d;
			v %= d;
			if (q || started || d == 1) {
				buf[n++] = (char)('0' + q);
				started = 1;
			}
		}
	}
	buf[n++] = ']';
	buf[n++] = ' ';
	for (; *fmt && n < sizeof(buf) - 24; fmt++) {
		if (*fmt != '%') {
			buf[n++] = *fmt;
			continue;
		}
		fmt++;
		if (*fmt == 's') {
			for (const char *s = __builtin_va_arg(ap, const char *); s && *s && n < sizeof(buf) - 24; s++)
				buf[n++] = *s;
		} else if (*fmt == 'S') {
			for (const WCHAR *s = __builtin_va_arg(ap, const WCHAR *); s && *s && n < sizeof(buf) - 24; s++)
				buf[n++] = (char)(*s < 128 ? *s : '?');
		} else if (*fmt == 'x') {
			UINT v = __builtin_va_arg(ap, UINT);
			buf[n++] = '0';
			buf[n++] = 'x';
			for (int i = 28; i >= 0; i -= 4)
				buf[n++] = "0123456789abcdef"[(v >> i) & 15];
		} else if (*fmt == 'u') {
			UINT v = __builtin_va_arg(ap, UINT), d = 1000000000;
			int started = 0;
			for (; d; d /= 10) {
				UINT q = v / d;
				v %= d;
				if (q || started || d == 1) {
					buf[n++] = (char)('0' + q);
					started = 1;
				}
			}
		} else {
			buf[n++] = *fmt;
		}
	}
	__builtin_va_end(ap);
	buf[n++] = '\r';
	buf[n++] = '\n';
	log_write(buf, n);
}

/* --- State ---------------------------------------------------------------- */
static PFND3DDDI_GETCAPS g_real_getcaps;
static PFND3DDDI_CREATEDEVICE g_real_createdevice;
static PFND3DDDI_CREATERESOURCE g_real_createresource;
static UINT g_real_format_count; /* last count the real driver reported */
static UINT g_null_backing;      /* format NULL resources are created with */
static int g_resource_logs = 200;

/*
 * Diagnostic mode: also advertise classic D3D9 formats the driver lacks, as
 * plain textures, so the runtime forwards such CreateTexture calls to the
 * driver and the "CreateResource FAILED" log names the format the game wants.
 */
#ifndef SHIM_DIAG_FORMATS
#define SHIM_DIAG_FORMATS 0
#endif
static const UINT g_diag_candidates[] = {
	20 /* R8G8B8 */,      27 /* R3G3B2 */,      29 /* A8R3G3B2 */,     30 /* X4R4G4B4 */,
	31 /* A2B10G10R10 */, 32 /* A8B8G8R8 */,     33 /* X8B8G8R8 */,     52 /* A4L4 */,
	61 /* L6V5U5 */,      110 /* Q16W16V16U16 */, 117 /* CxV8U8 */,      118 /* A1 */,
};
#define DIAG_N (sizeof(g_diag_candidates) / sizeof(g_diag_candidates[0]))
static UINT g_diag_extra[DIAG_N];
static UINT g_diag_count;
static FORMATOP g_scratch[256];

/* --- Adapter hooks ---------------------------------------------------------- */
static int find_format(const FORMATOP *ops, UINT n, UINT fmt, UINT need)
{
	for (UINT i = 0; i < n; i++)
		if (ops[i].Format == fmt && (ops[i].Operations & need) == need)
			return (int)i;
	return -1;
}

/* Fill g_diag_extra with the candidates missing from the driver's list. */
static void diag_scan(HANDLE adapter, UINT n)
{
	D3DDDIARG_GETCAPS q;

	g_diag_count = 0;
	if (!SHIM_DIAG_FORMATS || n > 256)
		return;
	q.Type = D3DDDICAPS_GETFORMATDATA;
	q.pInfo = 0;
	q.pData = g_scratch;
	q.DataSize = n * sizeof(FORMATOP);
	if (!SUCCEEDED(g_real_getcaps(adapter, &q)))
		return;
	for (UINT i = 0; i < DIAG_N; i++)
		if (find_format(g_scratch, n, g_diag_candidates[i], 0) < 0)
			g_diag_extra[g_diag_count++] = g_diag_candidates[i];
}

static HRESULT APIENTRY shim_getcaps(HANDLE adapter, const D3DDDIARG_GETCAPS *a)
{
	if (a && a->Type == D3DDDICAPS_GETFORMATCOUNT && a->pData && a->DataSize >= sizeof(UINT)) {
		HRESULT hr = g_real_getcaps(adapter, a);
		if (SUCCEEDED(hr)) {
			g_real_format_count = *(UINT *)a->pData;
			diag_scan(adapter, g_real_format_count);
			*(UINT *)a->pData = g_real_format_count + 1 + g_diag_count;
			shimlog("GETFORMATCOUNT real=%u reported=%u", g_real_format_count,
				g_real_format_count + 1 + g_diag_count);
		}
		return hr;
	}

	if (a && a->Type == D3DDDICAPS_GETFORMATDATA && a->pData && g_real_format_count &&
	    a->DataSize == (g_real_format_count + 1 + g_diag_count) * sizeof(FORMATOP)) {
		D3DDDIARG_GETCAPS real = *a;
		FORMATOP *ops = a->pData;
		UINT n = g_real_format_count;
		UINT need = FORMATOP_TEXTURE | FORMATOP_OFFSCREEN_RENDERTARGET;
		HRESULT hr;
		int t;

		real.DataSize = n * sizeof(FORMATOP);
		hr = g_real_getcaps(adapter, &real);
		if (!SUCCEEDED(hr))
			return hr;

		/* Diagnostic: let block-compressed formats be volume textures too. */
		if (SHIM_DIAG_FORMATS)
			for (UINT i = 0; i < n; i++) {
				UINT f = ops[i].Format;
				if (f == MAKEFOURCC('D', 'X', 'T', '1') || f == MAKEFOURCC('D', 'X', 'T', '2') ||
				    f == MAKEFOURCC('D', 'X', 'T', '3') || f == MAKEFOURCC('D', 'X', 'T', '4') ||
				    f == MAKEFOURCC('D', 'X', 'T', '5') || f == MAKEFOURCC('A', 'T', 'I', '1') ||
				    f == MAKEFOURCC('A', 'T', 'I', '2'))
					ops[i].Operations |= 0x2 /* VOLUMETEXTURE */;
			}

		/* Diagnostic extras go after the NULL entry (slot n). */
		for (UINT i = 0; i < g_diag_count; i++) {
			FORMATOP *e = &ops[n + 1 + i];
			e->Format = g_diag_extra[i];
			e->Operations = FORMATOP_TEXTURE | 0x2 /* VOLUME */ | 0x4 /* CUBE */ | 0x4000 /* OFFSCREENPLAIN */;
			e->FlipMsTypes = 0;
			e->BltMsTypes = 0;
			e->PrivateFormatBitCount = 0;
			shimlog("DIAG advertising format %u", e->Format);
		}

		{
			static int listed;
			if (!listed) {
				listed = 1;
				for (UINT i = 0; i < n; i++)
					shimlog("FORMAT %u: fmt=%x ops=%x", i, ops[i].Format, ops[i].Operations);
			}
		}

		t = find_format(ops, n, D3DDDIFMT_NULL, 0);
		if (t >= 0) {
			/* Driver already has NULL: keep the list valid with a duplicate. */
			ops[n] = ops[t];
			shimlog("GETFORMATDATA driver already exposes NULL (entry %u)", (UINT)t);
			return hr;
		}
		t = find_format(ops, n, D3DDDIFMT_R5G6B5, need);
		if (t < 0)
			t = find_format(ops, n, D3DDDIFMT_X8R8G8B8, need);
		if (t < 0)
			t = find_format(ops, n, D3DDDIFMT_A8R8G8B8, need);
		if (t < 0) {
			/* No usable backing format: report the list unchanged + a copy of entry 0. */
			ops[n] = ops[0];
			shimlog("GETFORMATDATA no render-target backing format found; NULL not added");
			return hr;
		}
		ops[n] = ops[t];
		ops[n].Format = D3DDDIFMT_NULL;
		/* Only what vendor drivers report for NULL: a render-target texture.
		 * Copying the backing format's ARGB-group/conversion/mipmap bits made
		 * the runtime give up on the adapter. */
		ops[n].Operations &= FORMATOP_TEXTURE | FORMATOP_OFFSCREEN_RENDERTARGET |
				     FORMATOP_SAME_FORMAT_RENDERTARGET;
		g_null_backing = ops[t].Format;
		shimlog("GETFORMATDATA added NULL backed by format %u ops=%x", ops[t].Format, ops[n].Operations);
		return hr;
	}

	if (a && (a->Type == D3DDDICAPS_GETFORMATDATA))
		shimlog("GETFORMATDATA unexpected size %u (real count %u), passing through", a->DataSize, g_real_format_count);
	return g_real_getcaps(adapter, a);
}

static HRESULT APIENTRY shim_createresource(HANDLE device, D3DDDIARG_CREATERESOURCE *r)
{
	HRESULT hr;
	const D3DDDI_SURFACEINFO *s = r ? r->pSurfList : 0;
	int plausible = r && s && r->SurfCount >= 1 && r->SurfCount <= 4096 &&
			s->Width >= 1 && s->Width <= 16384 && s->Height >= 1 && s->Height <= 16384;

	if (r) {
		/* Log the first resource of every (format, pool) pair, plus a running total. */
		static UINT seen[128][2], nseen, total;
		UINT i;

		total++;
		for (i = 0; i < nseen; i++)
			if (seen[i][0] == r->Format && seen[i][1] == r->Pool)
				break;
		if (i == nseen && nseen < 128) {
			seen[nseen][0] = r->Format;
			seen[nseen][1] = r->Pool;
			nseen++;
			shimlog("CreateResource #%u new fmt=%x pool=%u surfs=%u mips=%u w=%u h=%u d=%u", total, r->Format,
				r->Pool, r->SurfCount, r->MipLevels, plausible ? s->Width : 0, plausible ? s->Height : 0,
				plausible ? s->Depth : 0);
		} else if (plausible && s->Depth > 1 && g_resource_logs > 0) {
			g_resource_logs--;
			shimlog("CreateResource #%u volume fmt=%x pool=%u mips=%u %ux%ux%u", total, r->Format, r->Pool,
				r->MipLevels, s->Width, s->Height, s->Depth);
		} else if (g_resource_logs > 0 && (total % 500) == 0) {
			g_resource_logs--;
			MEMSTAT m;
			m.dwLength = sizeof(m);
			GlobalMemoryStatusEx(&m);
			shimlog("CreateResource total=%u free-address-space=%uMB of %uMB", total,
				(UINT)(m.AvailVirtual >> 20), (UINT)(m.TotalVirtual >> 20));
		}
	}

	if (r && r->Format == D3DDDIFMT_NULL && g_null_backing && plausible) {
		r->Format = g_null_backing;
		hr = g_real_createresource(device, r);
		r->Format = D3DDDIFMT_NULL;
		shimlog("CreateResource NULL %ux%u -> backing %u hr=%x", s->Width, s->Height, g_null_backing, (UINT)hr);
		return hr;
	}
	hr = g_real_createresource(device, r);
	if (!SUCCEEDED(hr) && r)
		shimlog("CreateResource FAILED hr=%x fmt=%x pool=%u surfs=%u mips=%u w=%u h=%u", (UINT)hr, r->Format,
			r->Pool, r->SurfCount, r->MipLevels, plausible ? s->Width : 0, plausible ? s->Height : 0);
	return hr;
}

static HRESULT APIENTRY shim_createdevice(HANDLE adapter, D3DDDIARG_CREATEDEVICE *a)
{
	HRESULT hr = g_real_createdevice(adapter, a);
	void **funcs;

	if (!SUCCEEDED(hr) || !a || !a->pDeviceFuncs) {
		shimlog("CreateDevice failed hr=%x", (UINT)hr);
		return hr;
	}
	funcs = a->pDeviceFuncs;
	if (!g_real_createresource)
		g_real_createresource = (PFND3DDDI_CREATERESOURCE)funcs[DEVICEFUNCS_SLOT_CREATERESOURCE];
	if (funcs[DEVICEFUNCS_SLOT_CREATERESOURCE] != (void *)g_real_createresource) {
		/* A different CreateResource per device would need per-device state. */
		shimlog("CreateDevice: CreateResource differs from first device (%x vs %x), not hooking",
		     (UINT)funcs[DEVICEFUNCS_SLOT_CREATERESOURCE], (UINT)g_real_createresource);
		return hr;
	}
	funcs[DEVICEFUNCS_SLOT_CREATERESOURCE] = (void *)shim_createresource;
	shimlog("CreateDevice ok interface=%x version=%x, CreateResource hooked", a->Interface, a->Version);
	return hr;
}

/* --- Entry ------------------------------------------------------------------ */
static void target_path(WCHAR *out, UINT cap)
{
	WCHAR name[64] = L"vm3dum.dll";
	UINT n = GetSystemDirectoryW(out, cap - 70);
	HKEY k;

	if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\win7ext\\umdshim", 0,
			  KEY_QUERY_VALUE | KEY_WOW64_64KEY, &k) == 0) {
		UINT type = 0, size = sizeof(name) - sizeof(WCHAR);
		WCHAR tmp[64];
		if (RegQueryValueExW(k, L"Target9", 0, &type, tmp, &size) == 0 && type == 1 /* REG_SZ */ &&
		    size >= 4 && size < sizeof(tmp)) {
			UINT i;
			tmp[size / sizeof(WCHAR)] = 0;
			/* Plain file name only: never load from an arbitrary path. */
			for (i = 0; tmp[i]; i++)
				if (tmp[i] == '\\' || tmp[i] == '/' || tmp[i] == ':')
					break;
			if (!tmp[i])
				memcpy(name, tmp, (i + 1) * sizeof(WCHAR));
		}
		RegCloseKey(k);
	}
	if (n == 0 || n >= cap - 70) {
		out[0] = 0;
		return;
	}
	out[n++] = '\\';
	for (UINT i = 0; name[i] && n < cap - 1; i++)
		out[n++] = name[i];
	out[n] = 0;
}

HRESULT APIENTRY OpenAdapter(D3DDDIARG_OPENADAPTER *a)
{
	WCHAR path[300], exe[260];
	HMODULE real;
	PFND3DDDI_OPENADAPTER real_open;
	HRESULT hr;

	exe[0] = 0;
	GetModuleFileNameW(0, exe, 260);
	target_path(path, 300);
	real = path[0] ? LoadLibraryW(path) : 0;
	real_open = real ? (PFND3DDDI_OPENADAPTER)(void *)GetProcAddress(real, "OpenAdapter") : 0;
	if (!real_open) {
		shimlog("OpenAdapter: cannot load real driver %S (process %S)", path, exe);
		return E_INVALIDARG;
	}

	hr = real_open(a);
	if (!SUCCEEDED(hr) || !a->pAdapterFuncs) {
		shimlog("OpenAdapter: real driver failed hr=%x", (UINT)hr);
		return hr;
	}
	g_real_getcaps = a->pAdapterFuncs->pfnGetCaps;
	g_real_createdevice = a->pAdapterFuncs->pfnCreateDevice;
	a->pAdapterFuncs->pfnGetCaps = shim_getcaps;
	a->pAdapterFuncs->pfnCreateDevice = shim_createdevice;
	shimlog("OpenAdapter ok: %S for %S, interface=%x version=%x driverversion=%x", path, exe, a->Interface,
	     a->Version, a->DriverVersion);
	return hr;
}

int __stdcall DllMain(HANDLE inst, UINT reason, void *reserved)
{
	(void)inst;
	(void)reason;
	(void)reserved;
	return 1;
}
