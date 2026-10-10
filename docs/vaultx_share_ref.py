"""
Implementazione di riferimento (indipendente da Swift) dei pacchetti protetti `.vaultxshare`.
Genera il vettore di test usato in VaultXTests/SharePackageTests.swift.
"""
import base64, hashlib, json, struct, unicodedata, uuid
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"VXSHR1"
KEY_INFO = b"VaultX share key v1"
TAG = 16

def nonce(counter, last):
    return b"\x00" * 7 + struct.pack(">I", counter) + (b"\x01" if last else b"\x00")

def derive_key(password, salt, iterations):
    normalized = unicodedata.normalize("NFC", password)
    password_key = hashlib.pbkdf2_hmac("sha256", normalized.encode(), salt, iterations)
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=b"", info=KEY_INFO).derive(password_key)

def create(password, salt, iterations, package_id, expires, name, content, created_iso, log2):
    header = MAGIC + bytes([log2]) + struct.pack(">I", iterations) + salt + package_id.bytes + struct.pack(">q", expires)
    assert len(header) == 51
    meta = json.dumps({"name": name, "size": len(content), "createdAt": created_iso}, separators=(",", ":")).encode()
    stream = struct.pack(">I", len(meta)) + meta + content
    size = 1 << log2
    chunks = [stream[i:i + size] for i in range(0, len(stream), size)] or [b""]
    key = AESGCM(derive_key(password, salt, iterations))
    body = b"".join(key.encrypt(nonce(i, i == len(chunks) - 1), c, header) for i, c in enumerate(chunks))
    return header + body

def open_package(password, blob):
    header, body = blob[:51], blob[51:]
    assert header[:6] == MAGIC
    log2 = header[6]
    iterations = struct.unpack(">I", header[7:11])[0]
    salt = header[11:27]
    key = AESGCM(derive_key(password, salt, iterations))
    cc = (1 << log2) + TAG
    parts = [body[i:i + cc] for i in range(0, len(body), cc)]
    stream = b"".join(key.decrypt(nonce(i, i == len(parts) - 1), p, header) for i, p in enumerate(parts))
    meta_len = struct.unpack(">I", stream[:4])[0]
    meta = json.loads(stream[4:4 + meta_len])
    return meta, stream[4 + meta_len:]

if __name__ == "__main__":
    password = "correct horse battery"
    salt = bytes(range(50, 66))
    package_id = uuid.UUID("11111111-2222-3333-4444-555555555555")
    content = bytes((i * 5 + 1) % 256 for i in range(3000))
    expires = 4102444800   # 2100-01-01T00:00:00Z

    blob = create(password, salt, 600_000, package_id, expires, "ref-note.txt", content, "2026-01-01T00:00:00Z", 10)
    meta, data = open_package(password, blob)
    assert data == content and meta["name"] == "ref-note.txt" and meta["size"] == 3000
    try:
        open_package("wrong password!", blob); raise SystemExit("password errata accettata")
    except Exception as e:
        assert "SystemExit" not in repr(e)

    print("SHARE_VECTOR_B64 =", base64.b64encode(blob).decode())
    print("blob bytes:", len(blob))
