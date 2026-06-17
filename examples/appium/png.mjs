// Minimal dependency-free PNG "is it non-black?" check, shared by the navigation
// test. Decodes the IDAT stream with Node's built-in zlib and returns the fraction
// of non-zero bytes in the decompressed scanlines — the same heuristic as the
// repo's python `nonblack` (examples/argent-screenshot-test.sh). A fully
// black/broken frame is ~0.000; anything rendered is well above the threshold.
// No image library needed.
import zlib from 'node:zlib';

// nonblackFrac(buf) -> { w, h, frac } for a valid PNG, or null if the buffer is
// not a decodable PNG.
export function nonblackFrac(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 8 || buf.readUInt32BE(0) !== 0x89504e47) return null;
  let i = 8;
  let w = 0;
  let h = 0;
  const idat = [];
  while (i + 8 <= buf.length) {
    const len = buf.readUInt32BE(i);
    const type = buf.toString('ascii', i + 4, i + 8);
    if (type === 'IHDR') {
      w = buf.readUInt32BE(i + 8);
      h = buf.readUInt32BE(i + 12);
    } else if (type === 'IDAT') {
      idat.push(buf.subarray(i + 8, i + 8 + len));
    }
    i += 12 + len;
    if (type === 'IEND') break;
  }
  if (idat.length === 0) return null;
  let raw;
  try {
    raw = zlib.inflateSync(Buffer.concat(idat));
  } catch {
    return null;
  }
  let nonzero = 0;
  for (let k = 0; k < raw.length; k++) if (raw[k] !== 0) nonzero++;
  return { w, h, frac: raw.length ? nonzero / raw.length : 0 };
}
