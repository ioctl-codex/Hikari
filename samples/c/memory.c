// Memory movement for the VMP interpreter.
//
// The interpreter models memory as a byte array addressed by pointer-sized
// values, so this file pins down the awkward cases: a load or store whose width
// differs from the value width, GEPs with several indices (struct + array + scalar),
// pointer casts (`int*` -> `char*` -> `short*`), and calls that take pointers
// (memcpy/memset/strlen).  A width mix-up here corrupts neighbouring fields
// rather than crashing, and the checksum at the end is the thing that notices.
//
// Build at -O0.

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define ANNO __attribute__((annotate("vmp")))

struct point {
  int x;
  int y;
  short tag;
  unsigned char flags;
  unsigned bits : 3;
  unsigned more : 5;
};

// ---------------------------------------------------------------- arrays ---
ANNO int array_ops(int n) {
  int buf[16];
  int i, acc = 0;

  for (i = 0; i < 16; i++) buf[i] = (i * 7 + n) ^ (i << 3);
  for (i = 15; i >= 0; i--) acc += buf[(i * 5) & 15];
  // Widening / narrowing through the element width.
  for (i = 0; i < 16; i++) buf[i] = (int)(unsigned char)(buf[i] * 3);
  for (i = 0; i < 16; i++) acc ^= buf[i];
  return acc;
}

ANNO int ptr_walk(int *p, int count) {
  int i, acc = 0;
  char *bytes = (char *)p;
  for (i = 0; i < count; i++) {
    int v = p[i];
    // Same bytes, read as two halves through a cast the interpreter has to
    // honour exactly.
    unsigned short lo = *(unsigned short *)(bytes + (i * 4));
    unsigned short hi = *(unsigned short *)(bytes + (i * 4) + 2);
    acc += (v & 0xffff) == lo ? 1 : 100;
    acc += ((v >> 16) & 0xffff) == hi ? 2 : 200;
  }
  return acc;
}

// --------------------------------------------------------------- structs ---
ANNO struct point make_point(int x, int y) {
  struct point p;
  p.x = x;
  p.y = y;
  p.tag = (short)(x - y);
  p.flags = (unsigned char)(x ^ y);
  p.bits = (unsigned)(x & 7);
  p.more = (unsigned)((x >> 3) & 31);
  return p;
}

ANNO int struct_ops(struct point *p, int n) {
  int i, acc = 0;
  for (i = 0; i < n; i++) {
    p[i].x = p[i].x + i;
    p[i].y = p[i].y - i;
    acc += p[i].x * 3 + p[i].y - p[i].tag;
    acc ^= (int)p[i].flags + (int)p[i].bits * 7 + (int)p[i].more * 13;
  }
  return acc;
}

union word {
  unsigned u;
  unsigned char b[4];
};

ANNO int union_ops(unsigned v) {
  union word w;
  int i, acc = 0;
  w.u = v;
  for (i = 0; i < 4; i++) acc += (int)w.b[i] << (i * 8);
  w.b[0] = (unsigned char)(v + 1);
  acc ^= (int)w.u;
  return acc;
}

// ----------------------------------------------------------------- libc ----
ANNO int libc_ops(const char *s, int n) {
  char tmp[24];
  size_t len = strlen(s);
  int acc = (int)len;

  memset(tmp, (char)(n & 0x7f), sizeof(tmp));
  memcpy(tmp, s, len < sizeof(tmp) ? len : sizeof(tmp));
  tmp[sizeof(tmp) - 1] = 0;
  for (int i = 0; i < 20; i++) acc += tmp[i];

  // A heap block the VM's own stack has to keep alive for the duration.
  int *heap = (int *)malloc(8 * sizeof(int));
  if (!heap) return -1;
  for (int i = 0; i < 8; i++) heap[i] = n + i * 3;
  for (int i = 0; i < 8; i++) acc ^= heap[i];
  free(heap);
  return acc;
}

// --------------------------------------------------------------- varargs ---
// Varargs make the pass refuse the function (it cannot model the va_list).
// The point of having it here is that the refusal must be local: the caller
// keeps running and the printed values stay correct.
ANNO int varargs_sum(int count, ...) {
  int acc = 0;
  __builtin_va_list ap;
  __builtin_va_start(ap, count);
  for (int i = 0; i < count; i++) acc += __builtin_va_arg(ap, int);
  __builtin_va_end(ap);
  return acc;
}

int main(void) {
  long long acc = 0;
  int arr[12];
  struct point pts[4];
  int i;

  for (i = 0; i < 12; i++) arr[i] = (i * 2654435761u) ^ (i << 13);
  for (i = 0; i < 4; i++) pts[i] = make_point(i * 101, -i * 37);

  for (i = 0; i < 6; i++) {
    acc += array_ops(i);
    acc += ptr_walk(arr, 12);
    acc += struct_ops(pts, 4);
    acc += union_ops((unsigned)(i * 0x01020304u));
    acc += libc_ops("hikari-memory", i);
    acc += varargs_sum(4, i, i * 2, i * 3, i * 4);
  }

  printf("acc=%lld\n", acc);
  printf("point=%d %d %d %u %u %u\n", pts[2].x, pts[2].y, (int)pts[2].tag,
         (unsigned)pts[2].flags, pts[2].bits, pts[2].more);
  printf("union=%d varargs=%d\n", union_ops(0xdeadbeefu), varargs_sum(3, 7, 8, 9));
  printf("str=%zu\n", strlen("hikari-memory"));
  return acc != 0 ? 0 : 1;
}
