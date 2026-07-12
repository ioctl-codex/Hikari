// VMP acceptance: arith, branch, GEP, call, globals, reentrancy.
// Prefer -O0. Annotate targets with "vmp".

#include <stdio.h>

static int g_factor = 3;

__attribute__((annotate("vmp")))
int vmp_add(int a, int b) {
  return a + b;
}

__attribute__((annotate("vmp")))
int vmp_abs(int x) {
  if (x < 0)
    return -x;
  return x;
}

__attribute__((annotate("vmp")))
int vmp_sum3(int a, int b, int c) {
  int t = a + b;
  return t + c;
}

__attribute__((annotate("vmp")))
int vmp_arr_sum(void) {
  int a[4];
  a[0] = 10;
  a[1] = 20;
  a[2] = 30;
  a[3] = 40;
  return a[0] + a[1] + a[2] + a[3];
}

static void my_copy(int *dst, int *src) { *dst = *src; }

__attribute__((annotate("vmp")))
int vmp_ptr_copy(void) {
  int a = 0;
  int b = 99;
  my_copy(&a, &b);
  return a;
}

__attribute__((annotate("vmp")))
int vmp_global(int x) {
  return x * g_factor;
}

static int helper_square(int x) { return x * x; }

__attribute__((annotate("vmp")))
int vmp_call_helper(int x) {
  return helper_square(x) + 1;
}

// Reentrancy: recursive VMP function (stack VM context).
__attribute__((annotate("vmp")))
int vmp_fact(int n) {
  if (n <= 1)
    return 1;
  return n * vmp_fact(n - 1);
}

// Multiple sequential calls into same VMP function.
__attribute__((annotate("vmp")))
int vmp_multi(int x) {
  return vmp_add(x, 1) + vmp_add(x, 2);
}

int main(void) {
  int r1 = vmp_add(40, 2);
  int r2 = vmp_abs(-7);
  int r3 = vmp_sum3(1, 2, 3);
  int r4 = vmp_arr_sum();
  int r5 = vmp_ptr_copy();
  int r6 = vmp_global(14);
  int r7 = vmp_call_helper(5);
  int r8 = vmp_fact(5);
  int r9 = vmp_multi(10);
  printf("add=%d abs=%d sum3=%d arr=%d ptr=%d glob=%d call=%d fact=%d multi=%d\n",
         r1, r2, r3, r4, r5, r6, r7, r8, r9);
  if (r1 != 42 || r2 != 7 || r3 != 6 || r4 != 100 || r5 != 99 || r6 != 42 ||
      r7 != 26 || r8 != 120 || r9 != 23)
    return 1;
  return 0;
}
