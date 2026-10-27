/*
 * Minimal D3D9 user-mode display driver interface (DDI) definitions used by
 * the shim. Written from Microsoft's public WDK reference documentation
 * (d3dumddi.h pages on learn.microsoft.com / MicrosoftDocs on GitHub); only
 * the members this shim touches are named, the rest are opaque.
 *
 * 32-bit (x86) only for now: all pointers and UINTs are 4 bytes.
 */
#pragma once

typedef unsigned int UINT;
typedef int HRESULT;
typedef void *HANDLE;
typedef unsigned short WCHAR;

#define APIENTRY __stdcall
#define S_OK 0
#define E_INVALIDARG ((HRESULT)0x80070057)
#define E_OUTOFMEMORY ((HRESULT)0x8007000E)
#define SUCCEEDED(hr) ((HRESULT)(hr) >= 0)

#define MAKEFOURCC(a, b, c, d) \
	((UINT)(unsigned char)(a) | ((UINT)(unsigned char)(b) << 8) | \
	 ((UINT)(unsigned char)(c) << 16) | ((UINT)(unsigned char)(d) << 24))

/* D3DDDIFORMAT values (same numbering as D3DFORMAT). */
#define D3DDDIFMT_A8R8G8B8 21
#define D3DDDIFMT_X8R8G8B8 22
#define D3DDDIFMT_R5G6B5 23
#define D3DDDIFMT_NULL MAKEFOURCC('N', 'U', 'L', 'L')

/* D3DDDICAPS_TYPE: enumeration starts at 1 (D3DDDICAPS_DDRAW). */
#define D3DDDICAPS_GETFORMATCOUNT 3
#define D3DDDICAPS_GETFORMATDATA 4

/* FORMATOP operation bits (FORMATOP structure documentation). */
#define FORMATOP_TEXTURE 0x00000001
#define FORMATOP_OFFSCREEN_RENDERTARGET 0x00000008
#define FORMATOP_SAME_FORMAT_RENDERTARGET 0x00000010
#define FORMATOP_DISPLAYMODE 0x00000400
#define FORMATOP_3DACCELERATION 0x00000800

typedef struct {
	UINT Format;
	UINT Operations;
	UINT FlipMsTypes;
	UINT BltMsTypes;
	UINT PrivateFormatBitCount;
} FORMATOP;

typedef struct {
	UINT Type;
	const void *pInfo;
	void *pData;
	UINT DataSize;
} D3DDDIARG_GETCAPS;

struct D3DDDIARG_CREATEDEVICE;

typedef HRESULT(APIENTRY *PFND3DDDI_GETCAPS)(HANDLE, const D3DDDIARG_GETCAPS *);
typedef HRESULT(APIENTRY *PFND3DDDI_CREATEDEVICE)(HANDLE, struct D3DDDIARG_CREATEDEVICE *);
typedef HRESULT(APIENTRY *PFND3DDDI_CLOSEADAPTER)(HANDLE);

typedef struct {
	PFND3DDDI_GETCAPS pfnGetCaps;
	PFND3DDDI_CREATEDEVICE pfnCreateDevice;
	PFND3DDDI_CLOSEADAPTER pfnCloseAdapter;
} D3DDDI_ADAPTERFUNCS;

typedef struct {
	HANDLE hAdapter;
	UINT Interface;
	UINT Version;
	const void *pAdapterCallbacks;
	D3DDDI_ADAPTERFUNCS *pAdapterFuncs;
	UINT DriverVersion;
} D3DDDIARG_OPENADAPTER;

typedef HRESULT(APIENTRY *PFND3DDDI_OPENADAPTER)(D3DDDIARG_OPENADAPTER *);

typedef struct D3DDDIARG_CREATEDEVICE {
	HANDLE hDevice;
	UINT Interface;
	UINT Version;
	const void *pCallbacks;
	void *pCommandBuffer;
	UINT CommandBufferSize;
	void *pAllocationList;
	UINT AllocationListSize;
	void *pPatchLocationList;
	UINT PatchLocationListSize;
	void **pDeviceFuncs; /* D3DDDI_DEVICEFUNCS: array of function pointers */
	UINT Flags;
} D3DDDIARG_CREATEDEVICE;

/* Slot of pfnCreateResource in D3DDDI_DEVICEFUNCS (0 = pfnSetRenderState). */
#define DEVICEFUNCS_SLOT_CREATERESOURCE 37

typedef struct {
	UINT Width;
	UINT Height;
	UINT Depth;
	const void *pSysMem;
	UINT SysMemPitch;
	UINT SysMemSlicePitch;
} D3DDDI_SURFACEINFO;

/* Leading members of D3DDDIARG_CREATERESOURCE; the rest is left alone. */
typedef struct {
	UINT Format;
	UINT Pool;
	UINT MultisampleType;
	UINT MultisampleQuality;
	const D3DDDI_SURFACEINFO *pSurfList;
	UINT SurfCount;
	UINT MipLevels;
} D3DDDIARG_CREATERESOURCE;

typedef HRESULT(APIENTRY *PFND3DDDI_CREATERESOURCE)(HANDLE, D3DDDIARG_CREATERESOURCE *);
