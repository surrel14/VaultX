"""
Implementazione di riferimento (indipendente da Swift) del formato file VaultX v3.
Serve a generare e verificare i vettori di test usati in VaultXTests.
"""
import base64, struct, uuid
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"VLTX03"
FILE_INFO = b"VaultX v3 file key"
INDEX_INFO = b"VaultX v3 index key"
TAG = 16

def hkdf(ikm, salt, info):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(ikm)

def nonce(counter, last):
    return b"\x00" * 7 + struct.pack(">I", counter) + (b"\x01" if last else b"\x00")

def encrypt(master, file_id: uuid.UUID, salt: bytes, plaintext: bytes, log2=16) -> bytes:
    chunk = 1 << log2
    header = MAGIC + bytes([log2]) + salt
    aad = header + file_id.bytes
    key = AESGCM(hkdf(master, salt, FILE_INFO))
    chunks = [plaintext[i:i + chunk] for i in range(0, len(plaintext), chunk)] or [b""]
    out = bytearray(header)
    for i, c in enumerate(chunks):
        out += key.encrypt(nonce(i, i == len(chunks) - 1), c, aad)   # ct||tag
    return bytes(out)

def decrypt(master, file_id: uuid.UUID, blob: bytes) -> bytes:
    header, body = blob[:39], blob[39:]
    assert header[:6] == MAGIC
    log2 = header[6]; salt = header[7:39]
    cipher_chunk = (1 << log2) + TAG
    key = AESGCM(hkdf(master, salt, FILE_INFO))
    aad = header + file_id.bytes
    parts = [body[i:i + cipher_chunk] for i in range(0, len(body), cipher_chunk)]
    out = b""
    for i, p in enumerate(parts):
        out += key.decrypt(nonce(i, i == len(parts) - 1), p, aad)
    return out

def plaintext_size(encrypted_size, log2=16):
    n = encrypted_size - 39
    cc = (1 << log2) + TAG
    chunks = (n + cc - 1) // cc
    return n - chunks * TAG

if __name__ == "__main__":
    master = bytes(range(32))
    fid = uuid.UUID("00112233-4455-6677-8899-AABBCCDDEEFF")
    salt = bytes(range(100, 132))
    plain = bytes((i * 7 + 3) % 256 for i in range(2500))

    blob = encrypt(master, fid, salt, plain, log2=10)
    assert decrypt(master, fid, blob) == plain
    assert plaintext_size(len(blob), 10) == len(plain)

    # casi limite
    for n in (0, 1, 1023, 1024, 1025, 2048, 3000):
        p = bytes(range(256)) * 12
        p = p[:n]
        b = encrypt(master, fid, salt, p, log2=10)
        assert decrypt(master, fid, b) == p and plaintext_size(len(b), 10) == n, n

    # manomissioni
    import copy
    bad = bytearray(blob); bad[100] ^= 1
    try: decrypt(master, fid, bytes(bad)); raise SystemExit("manomissione non rilevata")
    except Exception as e: assert "SystemExit" not in repr(e)
    try: decrypt(master, fid, blob[:39 + 1040]); raise SystemExit("troncamento non rilevato")   # taglia all'ultimo chunk intero
    except Exception as e: assert "SystemExit" not in repr(e)
    try: decrypt(master, uuid.UUID(int=1), blob); raise SystemExit("file ID non legato")
    except Exception as e: assert "SystemExit" not in repr(e)

    print("VECTOR_FILE_B64 =", base64.b64encode(blob).decode())
    print("FILE_KEY_HEX =", hkdf(master, salt, FILE_INFO).hex())
    print("INDEX_KEY_HEX =", hkdf(master, b"", INDEX_INFO).hex())
    print("blob bytes:", len(blob), "plain bytes:", len(plain))
