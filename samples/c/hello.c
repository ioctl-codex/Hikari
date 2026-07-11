#include <stdio.h>
#include <string.h>

static int check_password(const char *input) {
  const char *secret = "hikari-secret-2026";
  if (strlen(input) != strlen(secret))
    return 0;
  int ok = 1;
  for (size_t i = 0; i < strlen(secret); i++) {
    if (input[i] != secret[i])
      ok = 0;
  }
  return ok;
}

static int classify(int x) {
  switch (x) {
  case 0:
    return 100;
  case 1:
    return 200;
  case 2:
    return 300;
  case 3:
    return 400;
  default:
    return -1;
  }
}

int main(int argc, char **argv) {
  const char *msg = "Hello from Hikari sample!";
  printf("%s\n", msg);

  int v = argc > 1 ? argv[1][0] - '0' : 2;
  printf("classify(%d) = %d\n", v, classify(v));

  if (argc > 2 && check_password(argv[2])) {
    printf("access granted\n");
    return 0;
  }
  printf("access denied\n");
  return 1;
}
