// Signed displacement: pointer arithmetic with negative, run-time indices.
//
// LLVM scales GEP indices as *signed* values, so `p[i]` with a negative `i`
// reaches backwards from `p`. At -O0 that becomes a `sext i32 -> i64` followed
// by the GEP, which is exactly the pair the VMP interpreter used to get wrong:
// it sign-extended from the destination width (making `(int64_t)(int32_t)-1`
// equal to 0x00000000FFFFFFFF) and read GEP displacements zero-extended. The
// result was a wild pointer, so this sample aborts instead of printing.
//
// Build at -O0, annotate the functions as "vmp".

#include <stdio.h>

static int table[6] = {10, 20, 30, 40, 50, 60};

__attribute__((annotate("vmp")))
int at(int *base, long index) { return base[index]; }

__attribute__((annotate("vmp")))
int span(int *base, int lo, int hi) {
  int acc = 0;
  for (int i = lo; i <= hi; i++)
    acc += base[i];
  return acc;
}

__attribute__((annotate("vmp")))
char *tail(char *s, int back) { return s - back; }

int main(void) {
  int *mid = table + 3;
  int a = at(mid, 0);   /* -> table[3] */
  int b = at(mid, -1);  /* -> table[2] */
  int c = at(mid, -3);  /* -> table[0] */
  int d = span(mid, -3, 0);
  int e = span(table, 1, 2);
  const char *msg = "abcdef";
  char *p = tail((char *)msg + 5, 2); /* back to 'd' */

  printf("a=%d b=%d c=%d d=%d e=%d p=%s\n", a, b, c, d, e, p);

  /* 40 30 10 100 50 def */
  return (a == 40 && b == 30 && c == 10 && d == 100 && e == 50 &&
          p[0] == 'd')
             ? 0
             : 1;
}
