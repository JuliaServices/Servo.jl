import org.jasypt.encryption.pbe.StandardPBEStringEncryptor;
import org.jasypt.salt.SaltGenerator;
import org.jasypt.iv.IvGenerator;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.io.*;

/**
 * Ground-truth Jasypt vector generator for Servo.Crypt parity testing.
 * Algorithm: PBEWITHHMACSHA512ANDAES_256 (matches Andavo EncryptionConfig).
 *
 * Modes:
 *   gen   -> print JSON-lines vectors (deterministic, fixed salt+iv) to stdout
 *   dec   -> read JSON-lines {password_hex, ct_b64} from stdin, print {plaintext_hex} (reverse cross-check)
 */
public class JasyptVectors {

    static String hex(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (byte x : b) s.append(String.format("%02x", x & 0xff));
        return s.toString();
    }
    static byte[] unhex(String h) {
        int n = h.length() / 2;
        byte[] b = new byte[n];
        for (int i = 0; i < n; i++) b[i] = (byte) Integer.parseInt(h.substring(2 * i, 2 * i + 2), 16);
        return b;
    }

    static boolean SIZE_LOGGED = false;

    static class FixedSalt implements SaltGenerator {
        final byte[] salt; FixedSalt(byte[] s) { salt = s; }
        public byte[] generateSalt(int lengthBytes) {
            if (!SIZE_LOGGED) { System.err.println("jasypt requested SALT bytes = " + lengthBytes); }
            byte[] r = new byte[lengthBytes];
            for (int i = 0; i < lengthBytes; i++) r[i] = salt[i % salt.length];
            return r;
        }
        public boolean includePlainSaltInEncryptionResults() { return true; }
    }
    static class FixedIv implements IvGenerator {
        final byte[] iv; FixedIv(byte[] v) { iv = v; }
        public byte[] generateIv(int lengthBytes) {
            if (!SIZE_LOGGED) { System.err.println("jasypt requested IV bytes = " + lengthBytes); SIZE_LOGGED = true; }
            byte[] r = new byte[lengthBytes];
            for (int i = 0; i < lengthBytes; i++) r[i] = iv[i % iv.length];
            return r;
        }
        public boolean includePlainIvInEncryptionResults() { return true; }
    }

    static StandardPBEStringEncryptor enc(String password, int iters, SaltGenerator sg, IvGenerator ig) {
        StandardPBEStringEncryptor e = new StandardPBEStringEncryptor();
        e.setPassword(password);
        e.setAlgorithm("PBEWITHHMACSHA512ANDAES_256");
        e.setKeyObtentionIterations(iters);
        e.setSaltGenerator(sg);
        e.setIvGenerator(ig);
        e.setProviderName("SunJCE");
        e.setStringOutputType("base64");
        return e;
    }

    static void emit(String pw, String pt, int iters, byte[] salt, byte[] iv) {
        StandardPBEStringEncryptor e = enc(pw, iters, new FixedSalt(salt), new FixedIv(iv));
        String ct = e.encrypt(pt);
        String back = e.decrypt(ct);
        if (!back.equals(pt)) throw new RuntimeException("self-decrypt mismatch for pt=" + pt);
        System.out.println(
            "{\"password_hex\":\"" + hex(pw.getBytes(StandardCharsets.UTF_8)) +
            "\",\"plaintext_hex\":\"" + hex(pt.getBytes(StandardCharsets.UTF_8)) +
            "\",\"iters\":" + iters +
            ",\"salt_hex\":\"" + hex(salt) +
            "\",\"iv_hex\":\"" + hex(iv) +
            "\",\"ct_b64\":\"" + ct + "\"}"
        );
    }

    static String repeat(String s, int n) { StringBuilder b = new StringBuilder(); for (int i = 0; i < n; i++) b.append(s); return b.toString(); }

    public static void main(String[] args) throws Exception {
        if (args.length > 0 && args[0].equals("dec")) {
            // reverse cross-check: stdin JSON-lines {password_hex, ct_b64} -> {plaintext_hex}
            BufferedReader br = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
            String line;
            while ((line = br.readLine()) != null) {
                if (line.trim().isEmpty()) continue;
                String pwHex = field(line, "password_hex");
                String ct = field(line, "ct_b64");
                int iters = Integer.parseInt(field(line, "iters"));
                String pw = new String(unhex(pwHex), StandardCharsets.UTF_8);
                StandardPBEStringEncryptor e = enc(pw, iters, new org.jasypt.salt.RandomSaltGenerator(), new org.jasypt.iv.RandomIvGenerator());
                String pt = e.decrypt(ct);
                System.out.println("{\"plaintext_hex\":\"" + hex(pt.getBytes(StandardCharsets.UTF_8)) + "\"}");
            }
            return;
        }

        // ---- generation matrix (deterministic) ----
        Random rnd = new Random(0xC0FFEE);
        byte[] salt16 = new byte[16]; rnd.nextBytes(salt16);
        byte[] iv16 = new byte[16];   rnd.nextBytes(iv16);

        // plaintext lengths probing block/padding boundaries
        int[] lens = {0, 1, 2, 15, 16, 17, 31, 32, 33, 63, 64, 100, 255, 1000};
        String[] passwords = {
            "admin", "s3cr3t", "ENCRYPTOR_PASSWORD_PRODUCTION",
            "a", "correct horse battery staple",
            repeat("x", 64), "p@ss w/ symbols !#$%^&*()_+-=[]{}|;:,.<>?"
        };

        // primary iteration count matches production (50000); add a few others for coverage
        int[] iterSet = {50000, 1000, 10000, 100000};

        for (String pw : passwords) {
            for (int L : lens) {
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < L; i++) sb.append((char) ('!' + (i % 90)));
                emit(pw, sb.toString(), 50000, salt16, iv16);
            }
        }
        // iteration sweep on a canonical value
        for (int it : iterSet) {
            emit("ENCRYPTOR_PASSWORD_PRODUCTION", "postgresql://andavoadmin:hunter2@db:5432/postgres", it, salt16, iv16);
        }
        // distinct salt/iv values to ensure salt/iv are honored (not hardcoded)
        for (int k = 0; k < 6; k++) {
            byte[] s = new byte[16]; rnd.nextBytes(s);
            byte[] v = new byte[16]; rnd.nextBytes(v);
            emit("rotation-key-" + k, "value-number-" + k + "-payload", 50000, s, v);
        }
        // unicode plaintext (UTF-8 multibyte) — tests plaintext byte handling
        emit("unicode-key", "héllo wörld — emoji 🚀🔐 ünïcödé", 50000, salt16, iv16);
        // unicode PASSWORD — tests SunJCE password char->byte encoding (known quirk)
        emit("pä$$wörd🔑", "secret-under-unicode-password", 50000, salt16, iv16);
    }

    // tiny hand-rolled field extractor for flat JSON lines (values are hex/base64/int, no nested quotes)
    static String field(String line, String key) {
        String k = "\"" + key + "\"";
        int i = line.indexOf(k);
        if (i < 0) throw new RuntimeException("missing " + key);
        int c = line.indexOf(':', i + k.length());
        int p = c + 1;
        while (p < line.length() && (line.charAt(p) == ' ')) p++;
        if (line.charAt(p) == '"') {
            int end = line.indexOf('"', p + 1);
            return line.substring(p + 1, end);
        } else {
            int end = p;
            while (end < line.length() && "-0123456789".indexOf(line.charAt(end)) >= 0) end++;
            return line.substring(p, end);
        }
    }
}
