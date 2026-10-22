-- Ed25519 via KOReader's bundled libcrypto (LibreSSL/OpenSSL), never Lua crypto.
-- https://docs.openssl.org/1.1.1/man7/Ed25519/
local S = {}
local ffi=require("ffi")
ffi.cdef[[
    typedef struct evp_pkey_st EVP_PKEY;
    typedef struct evp_md_ctx_st EVP_MD_CTX;
    int OBJ_txt2nid(const char *);
    EVP_PKEY *EVP_PKEY_new_raw_public_key(int, void *, const unsigned char *, size_t);
    void EVP_PKEY_free(EVP_PKEY *);
    EVP_MD_CTX *EVP_MD_CTX_new(void);
    void EVP_MD_CTX_free(EVP_MD_CTX *);
    int EVP_DigestVerifyInit(EVP_MD_CTX *, void *, const void *, void *, EVP_PKEY *);
    int EVP_DigestVerify(EVP_MD_CTX *, const unsigned char *, size_t, const unsigned char *, size_t);
]]
function S.hex(raw) return (raw:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end
function S.unhex(hex, bytes)
    assert(type(hex)=="string" and #hex==bytes*2 and hex:match("^[0-9a-f]+$"), "签名编码无效")
    return (hex:gsub('..',function(c) return string.char(tonumber(c,16)) end))
end
function S.fingerprint(key)
    return require("ffi/sha2").sha256(S.unhex(key,32))
end
function S.verify(key, signature, purpose, raw)
    assert(purpose=="index" or purpose=="package" or purpose=="rotation", "签名用途无效")
    local public,sig=S.unhex(key,32),S.unhex(signature,64)
    local lib=ffi.loadlib("crypto","57")
    local nid=lib.OBJ_txt2nid("Ed25519")
    if nid==0 then nid=lib.OBJ_txt2nid("ED25519") end
    assert(nid~=0, "当前 KOReader 加密库不支持 Ed25519")
    local p=lib.EVP_PKEY_new_raw_public_key(nid,nil,public,#public)
    assert(p~=nil, "无法加载 Ed25519 公钥")
    p=ffi.gc(p,lib.EVP_PKEY_free)
    local md=lib.EVP_MD_CTX_new(); assert(md~=nil,"无法创建验签上下文")
    md=ffi.gc(md,lib.EVP_MD_CTX_free)
    assert(lib.EVP_DigestVerifyInit(md,nil,nil,nil,p)==1,"无法初始化 Ed25519 验签")
    local message="PicaYomi/"..purpose.."/v1\0"..raw
    local ok=lib.EVP_DigestVerify(md,sig,#sig,message,#message)==1
    ffi.gc(md,nil); lib.EVP_MD_CTX_free(md)
    ffi.gc(p,nil); lib.EVP_PKEY_free(p)
    assert(ok,"Ed25519 签名校验失败")
    return true
end
return S
