// Integer arithmetic for the VMP interpreter, one function per opcode family.
//
// The interpreter decodes opcodes at run time, so each family needs its own
// call: add/sub/mul, udiv/sdiv, urem/srem, shl/lshr/ashr, and/or/xor, the six
// comparisons, select, and the width changes (trunc/zext/sext).  Width changes
// are where this pass has broken before — sign extension keyed off the
// destination width, and a `p[i]` with a negative index read a zero-extended
// displacement — so the cases here are deliberately redundant: the same value is
// computed through several shapes and must agree.
//
// Everything stays in integers; floating point makes the pass skip a function
// (see arith_float below, which asserts that skip stays harmless).
//
// Build at -O0.

#include <stdio.h>

#define ANNO __attribute__((annotate("vmp")))

// ---------------------------------------------------------------- binops ---
ANNO int add_sub(int a, int b) { return (a + b) - (b - a) + (a - b); }
ANNO int mul_div(int a, int b) { return a * b / (b == 0 ? 1 : b); }
ANNO unsigned udiv_urem(unsigned a, unsigned b) {
  if (b == 0) b = 1;
  return a / b + a % b;
}
ANNO int sdiv_srem(int a, int b) {
  if (b == 0) b = 1;
  return a / b + a % b;
}
ANNO int shifts(int x, int n) {
  // Left/right shifts with a run-time count, including counts that exceed the
  // width (undefined in C, defined in LLVM IR — a mismatch here means the
  // interpreter clamped differently than the host instruction stream).
  return (x << (n & 31)) ^ (x >> (n & 31));
}
ANNO unsigned lshr_unsigned(unsigned x, unsigned n) { return x >> (n & 31); }
ANNO int bitwise(int a, int b) { return (a & b) | (a ^ b) | ~(a | b); }

// ------------------------------------------------------------ compares -----
ANNO int compare(int a, int b) {
  int r = 0;
  if (a == b) r += 1;
  if (a != b) r += 2;
  if (a < b) r += 4;
  if (a <= b) r += 8;
  if (a > b) r += 16;
  if (a >= b) r += 32;
  return r;
}
ANNO int compare_unsigned(unsigned a, unsigned b) {
  int r = 0;
  if (a < b) r += 1;
  if (a > b) r += 2;
  if (a <= b) r += 4;
  if (a >= b) r += 8;
  return r;
}
ANNO int select_neg(int a, int b) { return (a < 0) ? -a : b; }

// ------------------------------------------------------------ widths -------
ANNO int width_mix(long long v) {
  signed char c = (signed char)v;           // trunc
  unsigned char uc = (unsigned char)v;      // trunc (unsigned)
  short s = (short)v;
  int i = (int)v;
  long long back = (long long)c + (long long)uc + (long long)s + (long long)i;
  // The same bytes, reached through zero extension instead of sign extension.
  unsigned long long zu = (unsigned long long)uc + (unsigned long long)(unsigned short)s;
  return (int)(back ^ (long long)zu) + (int)((i >> 3) - (int)(c << 1));
}
ANNO long long wide(long long a, long long b) {
  long long m = a * b;
  long long d = (b == 0) ? 1 : m / b;
  return (m ^ d) + (a << 17) - (b >> 3);
}
ANNO unsigned long long wide_unsigned(unsigned long long a, unsigned long long b) {
  if (b == 0) b = 1;
  return (a * b) ^ (a / b) ^ (a % b);
}
ANNO int narrow_ops(int a, int b) {
  unsigned char x = (unsigned char)a;
  unsigned char y = (unsigned char)b;
  unsigned char s = (unsigned char)(x + y);
  unsigned char m = (unsigned char)(x * y);
  // Promote through int, so the wrap above must survive the round trip.
  return (int)s * 256 + (int)m + (int)((unsigned char)(x - y));
}

// ---------------------------------------------------------------- edges ----
ANNO unsigned int_edges(unsigned x) {
  unsigned r = 0;
  r += x + 1u;                 // wraps at 0xFFFFFFFF
  r ^= x * 2u;
  r += (x >> 31) & 1u;         // top bit
  r ^= (~x);
  return r;
}
ANNO long long sign_edges(long long x) {
  long long r = x;
  r = r * -1;                  // negation, including LLONG_MIN
  r = r + 0x7fffffffffffffffLL;
  r = r - 0x7fffffffffffffffLL;
  return r ^ (x >> 63);        // arithmetic shift: all ones for negatives
}

// --------------------------------------------------------------- float -----
// The pass refuses floating-point IR ("hard-fail skip"), so this must stay
// correct without being virtualized, and must not take its caller down with it.
ANNO double arith_float(double x, double y) {
  double s = x + y;
  if (s > 1.0) s = s / 2.0;
  return s - y;
}

int main(void) {
  long long acc = 0;
  int i;

  for (i = -4; i <= 4; i++) {
    acc += add_sub(i * 37, 11);
    acc += mul_div(i, 3);
    acc += (long long)udiv_urem((unsigned)(i * 1000003), 7u);
    acc += sdiv_srem(i * 7 - 3, 3);
    acc += shifts(i * 129, i + 5);
    acc += (long long)lshr_unsigned((unsigned)(i * 2654435761u), (unsigned)(i & 31));
    acc += bitwise(i, i * 31);
    acc += compare(i, i % 3);
    acc += compare_unsigned((unsigned)i, (unsigned)(i % 3));
    acc += select_neg(i, i + 2);
    acc += width_mix((long long)i * 1234567890123LL);
    acc += (int)wide(i * 99991LL, i - 5);
    acc += (int)wide_unsigned((unsigned long long)(i * 7777777u), 13u);
    acc += narrow_ops(i * 213, i + 9);
    acc += (int)int_edges((unsigned)(i * 424242u));
    acc += (int)(sign_edges(i * 88172645463325252LL) & 0xffff);
  }

  printf("acc=%lld\n", acc);
  printf("float=%.6f\n", arith_float(3.5, 1.25));
  printf("edges=%u %lld\n", int_edges(0xffffffffu), sign_edges(-1));

  // Cross-check a few shapes that must agree with each other.
  printf("agree=%d %lld\n", add_sub(1234, -5678),
         wide(-9223372036854775807LL, 3));
  // arith_float(3.5, 1.25) = (3.5 + 1.25) / 2 - 1.25, every step exact in binary.
  return (acc != 0 && arith_float(3.5, 1.25) == 1.125) ? 0 : 1;
}
