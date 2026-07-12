// Complex-ish control/data flow sample for VMP before/after comparison.
// Stay within VMP-supported IR: integers, branches, arrays/GEP, calls, globals.
// Build at -O0.

#include <stdio.h>

static int g_key = 0x5A5A;

static int rotl32(int x, int n) {
  unsigned u = (unsigned)x;
  n &= 31;
  return (int)((u << n) | (u >> (32 - n)));
}

static int mix(int a, int b) {
  int x = a ^ b;
  x = x + g_key;
  x = rotl32(x, 3);
  x = x * 0x45d9f3b;
  x = x ^ (x >> 16);
  return x;
}

// Core logic to virtualize: nested branches, loop, table, helper calls.
__attribute__((annotate("vmp")))
int license_score(int uid, int feature, int nonce) {
  int table[8];
  int i;
  int acc = uid ^ nonce;

  for (i = 0; i < 8; i = i + 1) {
    table[i] = mix(uid + i, feature ^ (i * 17));
  }

  if (feature < 0) {
    acc = -acc;
  } else if (feature == 0) {
    acc = acc + 1;
  } else if (feature < 10) {
    acc = acc + table[feature & 7];
  } else {
    acc = acc ^ table[(feature >> 2) & 7];
    if ((nonce & 1) != 0) {
      acc = mix(acc, table[3]);
    } else {
      acc = mix(table[5], acc);
    }
  }

  // Fold table
  for (i = 0; i < 8; i = i + 1) {
    if ((i & 1) == 0) {
      acc = acc + table[i];
    } else {
      acc = acc ^ table[i];
    }
  }

  // Final gate
  if (acc < 0) {
    acc = -acc;
  }
  acc = acc & 0x7fffffff;
  if (acc == 0) {
    acc = 1;
  }
  return acc;
}

int main(void) {
  int s1 = license_score(1001, 3, 0x11);
  int s2 = license_score(1001, 42, 0x22);
  int s3 = license_score(7, -1, 0x33);
  printf("s1=%d s2=%d s3=%d\n", s1, s2, s3);
  // Fixed expected values under this algorithm (for smoke).
  // Printed so we can verify VMP parity without hardcoding brittle constants.
  return 0;
}
