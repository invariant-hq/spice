(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Eval = Spice_eval

type suite = All | Smoke | Screen | Core | Long | Robustness

let all_suite = All
let smoke_suite = Smoke

let pp_suite ppf = function
  | All -> Format.pp_print_string ppf "all"
  | Smoke -> Format.pp_print_string ppf "smoke"
  | Screen -> Format.pp_print_string ppf "screen"
  | Core -> Format.pp_print_string ppf "core"
  | Long -> Format.pp_print_string ppf "long"
  | Robustness -> Format.pp_print_string ppf "robustness"

let suite_of_string = function
  | "all" -> Ok All
  | "smoke" -> Ok Smoke
  | "screen" -> Ok Screen
  | "core" -> Ok Core
  | "long" -> Ok Long
  | "robustness" -> Ok Robustness
  | raw -> Error (`Msg ("unknown suite: " ^ raw))

let dune_build =
  Eval.Check.gate "build" (Eval.Check.shell "dune build --root .")

let dune_test =
  Eval.Check.gate "test" (Eval.Check.shell "dune runtest --root .")

let scope ~within =
  Eval.Check.penalty "scope" ~points:0.25 (Eval.Check.diff_within within)

let no_silenced_warnings =
  Eval.Check.penalty "no-silenced-warnings" ~points:0.25
    (Eval.Check.diff_free_of "\\[@+\\(ocaml\\.\\)?warning[ \t]*\"?-")

let task ?(tags = []) ?(metadata = []) ?(oracle = "checks") id ~tier ~category
    ~size ~source ~prompt checks =
  Eval.Task.make
    ~tags:(tier :: category :: size :: tags)
    ~metadata:
      ([
         ("tier", tier);
         ("category", category);
         ("size", size);
         ("oracle", oracle);
       ]
      @ metadata)
    id ~source ~prompt checks

let hidden_test ~name ~libraries body =
  Eval.Check.gate ("hidden-" ^ name)
    (Eval.Check.shell
       (Printf.sprintf
          "mkdir -p test\n\
           cat > test/%s.ml <<'EOF'\n\
           %s\n\
           EOF\n\
           cat >> test/dune <<'EOF'\n\
           (test\n\
          \ (name %s)\n\
          \ (libraries %s))\n\
           EOF\n\
           dune runtest --root ."
          name body name libraries))

let smoke_task =
  task "smoke-edit" ~tier:"smoke" ~category:"bugfix" ~size:"S"
    ~source:(Eval.Task.dir "eval/fixtures/smoke_project")
    ~prompt:
      "Make the smallest correct edit so lib/basics.ml defines answer as 42. \
       Do not edit dune-project."
    [
      dune_build;
      Eval.Check.gate "answer"
        (Eval.Check.shell "grep -q 'let answer = 42' lib/basics.ml");
      scope ~within:[ "lib/**" ];
    ]

let words_bugfix =
  task "words-rev-bugfix" ~tier:"core" ~category:"bugfix" ~size:"S"
    ~source:(Eval.Task.dir "eval/fixtures/words_project")
    ~prompt:
      "The test suite fails: rev_words must reverse the order of \
       space-separated words. Fix the implementation in lib/words.ml. Do not \
       change the tests."
    [
      dune_build;
      dune_test;
      Eval.Check.gate "fix-in-lib-only" (Eval.Check.diff_within [ "lib/**" ]);
      no_silenced_warnings;
      Eval.Check.judge "fix-quality"
        ~criterion:
          "Is the fix minimal and idiomatic OCaml, addressing the actual bug \
           rather than special-casing the tests?"
        ();
    ]

let greeter_refactor =
  task "greeter-rename-refactor" ~tier:"core" ~category:"refactor" ~size:"S"
    ~source:(Eval.Task.dir "eval/fixtures/greeter_project")
    ~prompt:
      "Rename the function greet to greeting across the whole project, \
       updating every call site. Keep behavior identical."
    [
      dune_build;
      Eval.Check.gate "renamed"
        (Eval.Check.shell
           "grep -q 'let greeting' lib/greeter.ml && ! grep -wq greet \
            lib/greeter.ml bin/main.ml");
      scope ~within:[ "lib/**"; "bin/**" ];
      Eval.Check.judge "refactor-quality"
        ~criterion:
          "Is the rename complete and exact, with no unrelated edits, \
           formatting churn, or leftover references to the old name?"
        ();
    ]

let counter_docs =
  task "counter-mli-docs" ~tier:"core" ~category:"docs" ~size:"S"
    ~source:(Eval.Task.dir "eval/fixtures/counter_project")
    ~prompt:
      "Document lib/counter.mli with odoc comments: add a module synopsis and \
       a documentation comment for every type and value. Do not change any \
       signature."
    [
      dune_build;
      Eval.Check.gate "documented"
        (Eval.Check.shell "grep -q '(\\*\\*' lib/counter.mli");
      Eval.Check.gate "docs-only" (Eval.Check.diff_within [ "lib/counter.mli" ]);
      Eval.Check.judge "docs-quality" ~weight:2.
        ~criterion:
          "Do the odoc comments follow OCaml documentation conventions \
           (synopsis first, value comments of the form [zero] is ..., accurate \
           and concise wording)?"
        ();
    ]

let calc_tests =
  task "calc-clamp-tests" ~tier:"core" ~category:"tests" ~size:"S"
    ~source:(Eval.Task.dir "eval/fixtures/calc_project")
    ~prompt:
      "Extend test/test_calc.ml with assertions covering the edge cases of \
       clamp: values below low, above high, and equal to each bound. Keep dune \
       runtest green and do not change the library."
    [
      dune_build;
      dune_test;
      Eval.Check.gate "tests-changed"
        (Eval.Check.diff_touches_any [ "test/**" ]);
      Eval.Check.gate "tests-only" (Eval.Check.diff_within [ "test/**" ]);
      Eval.Check.judge "test-quality"
        ~criterion:
          "Do the added assertions genuinely cover the boundary cases of clamp \
           (below low, above high, at each bound) with correct expected \
           values?"
        ();
    ]

let ledger_signed_total =
  task "ledger-signed-total-bugfix" ~tier:"core" ~category:"bugfix" ~size:"S"
    ~oracle:"checks+hidden"
    ~source:(Eval.Task.dir "eval/fixtures/ledger_project")
    ~prompt:
      "Ledger balances are wrong when an entry amount is already negative. Fix \
       the bug without changing the public entry type or the public signature."
    [
      dune_build;
      dune_test;
      hidden_test ~name:"hidden_ledger" ~libraries:"ledger"
        {|
let entries =
  [
    { Ledger.account = "cash"; amount = 100 };
    { Ledger.account = "cash"; amount = 0 };
    { Ledger.account = "cash"; amount = -40 };
    { Ledger.account = "sales"; amount = 7 };
    { Ledger.account = "cash"; amount = -3 };
    { Ledger.account = "refunds"; amount = -11 };
    { Ledger.account = "sales"; amount = 13 };
  ]

let () =
  assert (Ledger.balance "cash" entries = 57);
  assert (Ledger.balance "sales" entries = 20);
  assert (Ledger.balance "refunds" entries = -11);
  assert (Ledger.balance "missing" entries = 0);
  print_endline "ok"
|};
      Eval.Check.gate "interface-unchanged"
        (Eval.Check.shell "git diff --exit-code HEAD -- lib/ledger.mli");
      Eval.Check.gate "lib-only" (Eval.Check.diff_within [ "lib/**" ]);
      no_silenced_warnings;
      Eval.Check.judge "fix-quality"
        ~criterion:
          "Does the fix preserve the public API and handle signed ledger \
           amounts generally rather than special-casing the visible test?"
        ();
    ]

let slug_feature =
  task "slug-normalization-feature" ~tier:"core" ~category:"feature" ~size:"S"
    ~oracle:"checks+hidden"
    ~source:(Eval.Task.dir "eval/fixtures/slug_project")
    ~prompt:
      "Extend slugify so it creates URL slugs: lowercase ASCII text, replace \
       each run of non-alphanumeric ASCII characters with one hyphen, and trim \
       leading or trailing hyphens. ASCII letters and digits are the only \
       alphanumeric characters."
    [
      dune_build;
      dune_test;
      hidden_test ~name:"hidden_slug" ~libraries:"slug"
        {|
let () =
  assert (Slug.slugify "  Hello, OCaml World!  " = "hello-ocaml-world");
  assert (Slug.slugify "Already---slugged" = "already-slugged");
  assert (Slug.slugify "Version 5.5.0" = "version-5-5-0");
  assert (Slug.slugify "a_b" = "a-b");
  assert (Slug.slugify "" = "");
  assert (Slug.slugify "--A--" = "a");
  assert (Slug.slugify "tabs\tand\nlines" = "tabs-and-lines");
  assert (Slug.slugify "!!!" = "");
  print_endline "ok"
|};
      Eval.Check.gate "lib-or-tests"
        (Eval.Check.diff_within [ "lib/**"; "test/**" ]);
      no_silenced_warnings;
      Eval.Check.judge "feature-quality"
        ~criterion:
          "Is the slugification behavior general and simple, without \
           hard-coding the visible examples or introducing unnecessary \
           dependencies?"
        ();
    ]

let stats_median_contract =
  task "stats-median-contract" ~tier:"robustness" ~category:"bugfix" ~size:"S"
    ~oracle:"checks+hidden"
    ~source:(Eval.Task.dir "eval/fixtures/stats_project")
    ~prompt:
      "Fix Stats.median according to its interface comment. Do not change the \
       tests or the public interface."
    [
      dune_build;
      dune_test;
      hidden_test ~name:"hidden_stats" ~libraries:"stats"
        {|
let close a b = Float.abs (a -. b) < 0.000001

let () =
  assert (close (Stats.median [ 4.; 1.; 2.; 3. ]) 2.5);
  assert (close (Stats.median [ 10.; -2.; 7. ]) 7.);
  assert (close (Stats.median [ 2.; 2.; 8.; 10. ]) 5.);
  (match Stats.median [] with
  | _ -> assert false
  | exception Invalid_argument _ -> ());
  print_endline "ok"
|};
      Eval.Check.gate "interface-unchanged"
        (Eval.Check.shell "git diff --exit-code HEAD -- lib/stats.mli");
      Eval.Check.gate "lib-only" (Eval.Check.diff_within [ "lib/**" ]);
      no_silenced_warnings;
      Eval.Check.judge "contract-quality"
        ~criterion:
          "Does the fix follow the documented median contract for odd, even, \
           duplicate, and empty inputs without changing the public API?"
        ();
    ]

let build_linking_fix =
  task "cli-build-linking-fix" ~tier:"core" ~category:"build" ~size:"S"
    ~oracle:"checks"
    ~source:(Eval.Task.dir "eval/fixtures/build_project")
    ~prompt:
      "`dune build` fails for the CLI executable because its dune stanza links \
       the wrong library. Fix the build configuration only."
    [
      dune_build;
      Eval.Check.gate "cli-output"
        (Eval.Check.shell "dune exec --root . -- ./bin/main.exe | grep -qx 42");
      Eval.Check.gate "dune-only" (Eval.Check.diff_within [ "bin/dune" ]);
    ]

let warning_real_fix =
  task "warning-real-fix" ~tier:"robustness" ~category:"bugfix" ~size:"S"
    ~oracle:"checks+hidden"
    ~source:(Eval.Task.dir "eval/fixtures/warning_project")
    ~prompt:
      "`dune build` fails because warnings are treated as errors. Fix the code \
       cleanly. Do not change dune flags, add warning attributes, or hide the \
       variable with an underscore."
    [
      dune_build;
      dune_test;
      hidden_test ~name:"hidden_warning" ~libraries:"warning_case"
        {|
let () =
  assert (Warning_case.normalize "\tMiXeD Case\n" = "mixed case");
  print_endline "ok"
|};
      Eval.Check.gate "implementation-only"
        (Eval.Check.diff_within [ "lib/warning_case.ml" ]);
      Eval.Check.gate "no-underscore-suppression"
        (Eval.Check.diff_free_of "let[ \t]*_");
      Eval.Check.gate "no-warning-attributes"
        (Eval.Check.diff_free_of "\\[@+\\(ocaml\\.\\)?warning[ \t]*\"?-");
      Eval.Check.gate "dead-binding-removed"
        (Eval.Check.shell
           "! grep -q 'unused_debug_copy\\|opaque_identity\\|ignore' \
            lib/warning_case.ml");
      no_silenced_warnings;
    ]

let auth_admin_bugfix =
  task "auth-admin-delete-bugfix" ~tier:"core" ~category:"bugfix" ~size:"S"
    ~oracle:"checks+hidden"
    ~source:(Eval.Task.dir "eval/fixtures/auth_project")
    ~prompt:
      "Fix the account deletion permission bug. Only active admins may delete \
       accounts; active non-admin users and inactive admins must be rejected."
    [
      dune_build;
      dune_test;
      hidden_test ~name:"hidden_auth" ~libraries:"auth"
        {|
let user name role active = { Auth.name; role; active }

let () =
  assert (Auth.can_delete_account (user "Ada" "admin" true));
  assert (not (Auth.can_delete_account (user "Bob" "member" true)));
  assert (not (Auth.can_delete_account (user "Eve" "admin" false)));
  assert (not (Auth.can_delete_account (user "Mallory" "member" false)));
  print_endline "ok"
|};
      Eval.Check.gate "lib-only" (Eval.Check.diff_within [ "lib/**" ]);
      no_silenced_warnings;
    ]

let queue_fifo_tests =
  task "queue-fifo-tests" ~tier:"core" ~category:"tests" ~size:"S"
    ~oracle:"checks+mutation"
    ~source:(Eval.Task.dir "eval/fixtures/queue_project")
    ~prompt:
      "Add black-box tests for the queue contract: FIFO order, empty dequeue, \
       and interleaved enqueue/dequeue. Do not change the library."
    [
      dune_build;
      dune_test;
      Eval.Check.gate "tests-only" (Eval.Check.diff_within [ "test/**" ]);
      Eval.Check.gate "tests-added" (Eval.Check.diff_touches_any [ "test/**" ]);
      Eval.Check.gate "kills-lifo-mutation"
        (Eval.Check.shell
           "cp lib/queue_contract.ml /tmp/spice-eval-queue-contract.ml\n\
            perl -0pi -e 's/let enqueue t x = t @ \\[ x \\]/let enqueue t x = \
            x :: t/' lib/queue_contract.ml\n\
            if dune runtest --root . >/tmp/spice-eval-queue-mutation.out 2>&1; \
            then\n\
           \  cat /tmp/spice-eval-queue-mutation.out\n\
           \  cp /tmp/spice-eval-queue-contract.ml lib/queue_contract.ml\n\
           \  exit 1\n\
            else\n\
           \  cp /tmp/spice-eval-queue-contract.ml lib/queue_contract.ml\n\
           \  dune runtest --root .\n\
            fi");
      Eval.Check.judge "test-quality"
        ~criterion:
          "Do the tests exercise the public FIFO queue contract through the \
           interface rather than depending on representation details?"
        ();
    ]

let smoke = [ smoke_task ]

let core =
  [
    words_bugfix;
    greeter_refactor;
    counter_docs;
    calc_tests;
    ledger_signed_total;
    slug_feature;
    build_linking_fix;
    auth_admin_bugfix;
    queue_fifo_tests;
  ]

let long = []
let robustness = [ stats_median_contract; warning_real_fix ]

(* The lab's inner-loop suite: one cheap task per category, chosen for fast,
   deterministic grading. Kept separate from [core] so screening iterations
   never touch the confirmation-only tasks. *)
let screen =
  [
    words_bugfix;
    greeter_refactor;
    counter_docs;
    calc_tests;
    slug_feature;
    build_linking_fix;
  ]

let all = smoke @ core @ long @ robustness

let tasks = function
  | All -> all
  | Smoke -> smoke
  | Screen -> screen
  | Core -> core
  | Long -> long
  | Robustness -> robustness
