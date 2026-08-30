// Minimal test harness: report every failure, exit non-zero if any fired.
// Deliberately dependency-free so `ctest` needs nothing fetched.
#ifndef VD_CHECK_H
#define VD_CHECK_H

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static int vd_failures = 0;  // NOLINT: tests read this directly
static int vd_checks = 0;

#define VD_CHECK(cond)                                                     \
  do {                                                                     \
    vd_checks++;                                                           \
    if (!(cond)) {                                                         \
      vd_failures++;                                                       \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);      \
    }                                                                      \
  } while (0)

#define VD_CHECK_EQ(actual, expected)                                      \
  do {                                                                     \
    vd_checks++;                                                           \
    int64_t vd_a = (int64_t)(actual);                                      \
    int64_t vd_e = (int64_t)(expected);                                    \
    if (vd_a != vd_e) {                                                    \
      vd_failures++;                                                       \
      fprintf(stderr, "FAIL %s:%d: %s\n  expected %" PRId64                \
                      "\n  actual   %" PRId64 "\n",                        \
              __FILE__, __LINE__, #actual, vd_e, vd_a);                    \
    }                                                                      \
  } while (0)

#define VD_CHECK_STR(actual, expected)                                     \
  do {                                                                     \
    vd_checks++;                                                           \
    if (strcmp((actual), (expected)) != 0) {                               \
      vd_failures++;                                                       \
      fprintf(stderr, "FAIL %s:%d: %s\n  expected \"%s\"\n  actual   \"%s\"\n", \
              __FILE__, __LINE__, #actual, (expected), (actual));          \
    }                                                                      \
  } while (0)

#define VD_REPORT()                                                        \
  (fprintf(stderr, "%s: %d checks, %d failed\n", __FILE__, vd_checks,      \
           vd_failures),                                                   \
   vd_failures == 0 ? 0 : 1)

#endif  // VD_CHECK_H
