/*
 * rime_probe.c —— 无 GUI 的 librime 测试器
 *
 * 用法：
 *   cc tools/rime_probe.c -I<librime>/src -o /tmp/rime_probe \
 *      /usr/lib64/librime.so.1 -Wl,-rpath,/usr/lib64
 *   /tmp/rime_probe <user_data_dir> [keys...]
 *
 * user_data_dir 里需要放好方案文件与 default.custom.yaml。
 * 不给 keys 时跑内置的一组测试。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "rime_api.h"

static RimeApi* api;

static void drain_candidates(RimeSessionId s);

static void show_candidates(RimeSessionId s) {
  const char* input = api->get_input(s);
  RimeContext ctx;
  memset(&ctx, 0, sizeof(ctx));
  RIME_STRUCT_INIT(RimeContext, ctx);
  if (api->get_context(s, &ctx)) {
    printf("  input=[%s] preedit=[%s]\n", input ? input : "",
           ctx.composition.preedit ? ctx.composition.preedit : "");
    api->free_context(&ctx);
  } else {
    printf("  input=[%s]\n", input ? input : "");
  }
  RimeCandidateListIterator it;
  memset(&it, 0, sizeof(it));
  if (!api->candidate_list_begin(s, &it)) {
    printf("    (no candidates)\n");
    return;
  }
  int n = 0;
  while (api->candidate_list_next(&it) && n < 12) {
    printf("    %2d. %-14s %s\n", n + 1, it.candidate.text,
           it.candidate.comment ? it.candidate.comment : "");
    ++n;
  }
  api->candidate_list_end(&it);
}

static void print_commit(RimeSessionId s) {
  RimeCommit commit;
  memset(&commit, 0, sizeof(commit));
  if (api->get_commit(s, &commit)) {
    printf("    commit: %s\n", commit.text);
    api->free_commit(&commit);
  }
}

static void run_case(const char* keys, int select_index) {
  RimeSessionId s = api->create_session();
  if (!s) {
    printf("create_session failed\n");
    return;
  }
  printf("keys \"%s\":\n", keys);
  for (const char* p = keys; *p; ++p) {
    /* 允许用 ` 表示空格，~ 表示 BackSpace，\\n 表示回车 */
    int kc = (*p == '`') ? ' ' : (*p == '~') ? 0xff08
             : (*p == '\n') ? 0xff0d : (unsigned char)*p;
    api->process_key(s, kc, 0);
    /* 模拟 UI 每键拉一次候选，让 menu/selected candidate 准备好 */
    drain_candidates(s);
  }
  show_candidates(s);
  if (select_index > 0) {
    /* 数字键选词（1 起）并上屏 */
    api->process_key(s, '0' + select_index, 0);
    print_commit(s);
  } else {
    print_commit(s);
  }
  api->destroy_session(s);
}

static double now_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void drain_candidates(RimeSessionId s) {
  RimeCandidateListIterator it;
  memset(&it, 0, sizeof(it));
  if (api->candidate_list_begin(s, &it)) {
    while (api->candidate_list_next(&it)) {
    }
    api->candidate_list_end(&it);
  }
}

static void bench(int rounds) {
  static const char* cases[] = {
      "wum",          "wumk",        "wumkuy",       "rkg;n",
      "uy;gr",        "sufy",        "qyprk",        "rkgj;ynp",
      "wumku;jgurk",  "wumkuy;jgurk", NULL};
  RimeSessionId s = api->create_session();
  api->select_schema(s, "xkjd27c_flow");
  int queries = 0;
  for (int warm = 0; warm < 2; ++warm) {
    double t0 = now_seconds();
    queries = 0;
    for (int i = 0; i < rounds; ++i) {
      for (int j = 0; cases[j]; ++j) {
        api->clear_composition(s);
        for (const char* p = cases[j]; *p; ++p) {
          api->process_key(s, (unsigned char)*p, 0);
        }
        drain_candidates(s);
        ++queries;
      }
    }
    double dt = now_seconds() - t0;
    if (warm > 0) {
      printf("bench: %d queries in %.3f s (%.3f ms/query)\n", queries, dt,
             dt * 1000 / queries);
    }
  }
  api->destroy_session(s);
}

int main(int argc, char** argv) {
  const char* user_dir = (argc > 1) ? argv[1] : "/tmp/rime_flow_test";

  api = rime_get_api();
  if (!api) {
    fprintf(stderr, "rime_get_api() returned NULL\n");
    return 1;
  }

  RimeTraits traits;
  memset(&traits, 0, sizeof(traits));
  RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = "/usr/share/rime-data";
  traits.user_data_dir = user_dir;
  traits.distribution_name = "Rime";
  traits.distribution_code_name = "rime_probe";
  traits.distribution_version = "1.16.1";
  traits.app_name = "rime.probe";
  traits.log_dir = "/tmp";

  api->setup(&traits);
  api->initialize(&traits);
  if (api->start_maintenance(True)) {
    api->join_maintenance_thread();
  }

  {
    RimeSessionId s = api->create_session();
    api->select_schema(s, "xkjd27c_flow");
    api->destroy_session(s);
  }

  if (argc > 2 && strcmp(argv[2], "--bench") == 0) {
    bench(argc > 3 ? atoi(argv[3]) : 200);
    api->finalize();
    return 0;
  }

  if (argc > 2) {
    int select_index = (argc > 3) ? atoi(argv[3]) : 0;
    run_case(argv[2], select_index);
  } else {
    /* 3 键词简码 */
    run_case("wum", 0);
    /* 3 键全码 */
    run_case("wwukmf", 0);
    /* 2 字词全码 */
    run_case("wumk", 0);
    /* 整句：我们 + 是 */
    run_case("wumkuy", 0);
    /* 4 字词节奏码：人 + 工/智/能 声母 */
    run_case("rkg;n", 0);
    /* 4 字词全码 */
    run_case("rkgj;ynp", 0);
    /* 3 字词：中国人（若词库有）*/
    run_case(";gr", 0);
    /* 1 全码 + 3 声母：是中国人 */
    run_case("uy;gr", 0);
    /* 上屏 + 用户词典学习 */
    run_case("wumk", 1);
    run_case("wumk", 0);
  }

  api->finalize();
  return 0;
}
