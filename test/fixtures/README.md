# Jasypt parity test vectors

`jasypt_vectors.jsonl` holds known-answer vectors produced by the **real**
`org.jasypt:jasypt:1.9.3` library. `test/crypt.jl` uses them to prove that
`Servo.Crypt.jasypt_encrypt` / `jasypt_decrypt` are byte-for-byte compatible with
Java Jasypt's `PBEWITHHMACSHA512ANDAES_256`.

## Encryptor configuration (the common jasypt-spring-boot setup)

| setting | value |
| --- | --- |
| algorithm | `PBEWITHHMACSHA512ANDAES_256` |
| key obtention iterations | 50000 (vectors also sweep 1000 / 10000 / 100000) |
| salt generator | `RandomSaltGenerator`, 16-byte salt (pinned per vector for reproducibility) |
| iv generator | `RandomIvGenerator`, 16-byte IV (pinned per vector for reproducibility) |
| provider | SunJCE |
| string output | base64 |

Wire format: `base64( salt[16] || iv[16] || AES-256-CBC/PKCS5(plaintext) )`,
key = `PBKDF2-HMAC-SHA512( UTF8(NFC(password)), salt, iterations, 32 )`, IV random & key-independent.

## Vector fields (one JSON object per line)

| field | meaning |
| --- | --- |
| `password_hex`  | UTF-8 bytes of the password |
| `plaintext_hex` | UTF-8 bytes of the plaintext |
| `iters`         | PBKDF2 iteration count |
| `salt_hex`      | 16-byte salt |
| `iv_hex`        | 16-byte IV |
| `ct_b64`        | the exact base64 string Jasypt produced |

## Regenerating

```sh
# jasypt-1.9.3.jar is on Maven Central (org.jasypt:jasypt:1.9.3)
javac -cp jasypt-1.9.3.jar -d out JasyptVectors.java
java  -cp "jasypt-1.9.3.jar:out" JasyptVectors gen > jasypt_vectors.jsonl
```

## Note on non-ASCII passwords

`PBEWITHHMACSHA512ANDAES_256` is a JCE *Cipher* (`PBES2Core`). On **JDK ≤ 20** the
password chars are masked with `& 0x7f` (7-bit) before PBKDF2; **JDK 21+** removed the
mask and uses straight UTF-8. These vectors were generated on JDK 25 (UTF-8), which is
what `Servo.Crypt` implements (UTF-8 of the NFC-normalized password). For **ASCII
passwords the two behaviours are identical**, so decryption matches regardless of which
JDK encrypted the value. Non-ASCII passwords encrypted on JDK ≤ 20 are out of scope.
