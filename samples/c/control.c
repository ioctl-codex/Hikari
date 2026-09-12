// Control flow for the VMP interpreter: what happens to the CFG *after* the VM
// lifts a function.
//
// The pass turns each annotated function into a bytecode program plus a dispatch
// loop, so every branch shape reaches the interpreter as a different opcode:
// conditional branches, unconditional ones, multi-way switches and calls.
// Getting one of them wrong usually shows up as an early exit or a skipped
// loop body rather than a crash, which is why the counters below are printed
// per shape instead of being folded into one number.
//
// Recursion is deliberately shallow.  A virtualized recursive function costs
// ~2400x the cycles of the original, so fib(15) spends half a minute under
// qemu and reads like a hang in a timeout-based gate; fib(12) recurses just as
// deep and keeps the cross-ABI matrix affordable.  Depth, not call count, is
// what exercises the interpreter's call opcode.
//
// Build at -O0.

#include <stdio.h>

#define ANNO __attribute__((annotate("vmp")))

// ---------------------------------------------------------------- loops ----
ANNO int loops(int n) {
  int i, j, acc = 0;
  for (i = 0; i < n; i++) {
    if ((i & 3) == 0) continue;
    acc += i;
    if (acc > 1000) break;
  }
  i = 0;
  while (i < n) {
    acc ^= i * 3;
    i += 2;
  }
  do {
    acc += 1;
    j = acc & 7;
    if (j == 0) continue;
    acc += j;
  } while (acc % 11 != 0 && acc < 100000);
  return acc;
}

ANNO int nested(int rows, int cols) {
  int r, c, acc = 0;
  for (r = 0; r < rows; r++) {
    for (c = 0; c < cols; c++) {
      if (r == c) continue;
      if (c > r + 2) break;
      acc += (r + 1) * (c + 1);
    }
  }
  return acc;
}

// -------------------------------------------------------------- switches ---
ANNO int switch_dense(int x) {
  int r;
  switch (x & 15) {  // dense: a jump table once lowered
    case 0: r = 11; break;
    case 1: r = 22; break;
    case 2: r = 33; break;
    case 3: r = 44; break;
    case 4: r = 55; break;
    case 5: r = 66; break;
    case 6: r = 77; break;
    case 7: r = 88; break;
    case 8: r = 99; break;
    case 9: r = 110; break;
    case 10: r = 121; break;
    case 11: r = 132; break;
    case 12: r = 143; break;
    case 13: r = 154; break;
    case 14: r = 165; break;
    default: r = 176; break;
  }
  return r;
}

ANNO int switch_sparse(int x) {
  int r = 0;
  switch (x) {  // sparse: compare chains, with fallthrough
    case -1000: r += 1;
    case 0: r += 2;
    case 7: r += 3;
    case 12345: r += 5;
    case 99999: r += 8; break;
    case 424242: r += 13; break;
    default: r += 21; break;
  }
  return r;
}

ANNO int switch_nested(int x, int y) {
  switch (x & 3) {
    case 0:
      switch (y & 3) {
        case 0: return 1;
        case 1: return 2;
        default: return 3;
      }
    case 1:
      return (y < 0) ? 4 : 5;
    default:
      return 6;
  }
}

// ----------------------------------------------------------------- goto ----
ANNO int goto_loop(int n) {
  int i = 0, acc = 0;
again:
  if (i >= n) goto done;
  acc += i * i;
  i++;
  if (i == 7) {
    i += 2;
    goto again;
  }
  goto again;
done:
  return acc;
}

// ------------------------------------------------------------ recursion ----
ANNO int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

ANNO int is_odd(int n);
ANNO int is_even(int n) { return n == 0 ? 1 : is_odd(n - 1); }
ANNO int is_odd(int n) { return n == 0 ? 0 : is_even(n - 1); }

// ------------------------------------------------------- function pointer --
ANNO int add_one(int x) { return x + 1; }
ANNO int times_three(int x) { return x * 3; }

ANNO int through_pointer(int x, int which) {
  int (*fn)(int) = which ? times_three : add_one;
  int acc = fn(x);
  // The pointer itself is data that survives the transform.
  acc += (*fn)(acc);
  return acc;
}

// ----------------------------------------------------------- indirectbr ----
// Computed goto lowers to `indirectbr` with a block-address table.  The pass
// has no opcode for that and must refuse the function rather than guess; if it
// does not, this returns a garbage value instead of 55.
ANNO int computed_goto(int x) {
  static void *table[] = {&&l0, &&l1, &&l2, &&l3};

  if (x < 0 || x > 3) return -1;
  goto *table[x];
l0:
  return 10;
l1:
  return 20;
l2:
  return 30;
l3:
  return 55;
}

int main(void) {
  long long acc = 0;
  int i;

  for (i = 0; i < 12; i++) {
    acc += loops(i * 3 + 1);
    acc += nested(i % 5 + 1, i % 4 + 1);
    acc += switch_dense(i * 5 - 7);
    acc += switch_sparse(i * 37 - 100);
    acc += switch_nested(i, -i);
    acc += goto_loop(i);
    acc += fib(i % 12);
    acc += is_even(i) ? 1000 : 2000;
    acc += through_pointer(i, i & 1);
    acc += computed_goto(i & 3);
  }

  printf("acc=%lld\n", acc);
  printf("shapes=%d %d %d %d\n", switch_dense(9), switch_sparse(-1000),
         goto_loop(10), computed_goto(3));
  printf("fnptr=%d %d\n", through_pointer(2, 0), through_pointer(2, 1));
  printf("rec=%d %d %d\n", fib(12), is_even(20), is_odd(20));
  return computed_goto(3) == 55 ? 0 : 1;
}
