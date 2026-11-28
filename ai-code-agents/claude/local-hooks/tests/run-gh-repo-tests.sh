#!/usr/bin/env bash
# Tests for gh-repo.sh and _gh_repo.py: the OWNER/REPO the git-pr and git-issue
# skills pass to gh as --repo. Throwaway repos under a temp dir with a temporary
# HOME; remotes are only configured URLs (nothing is fetched, no network, gh is
# never run).
# Usage: local-hooks/tests/run-gh-repo-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
export GIT_CONFIG_GLOBAL="$HOME/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@example.invalid
git config --global init.defaultBranch main
script="$hooks/gh-repo.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1${2:+ ($2)}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

T="$(mktemp -d "$HOME/t.XXXXXX")"
run() { bash "$script" --dir "$1" 2>/dev/null; }          # stdout
rcof() { bash "$script" --dir "$1" >/dev/null 2>&1; echo $?; }

# mk NAME: repo on branch feat with origin (acme/widgets) and upstream (public/widgets, push disabled)
mk() {
  local d="$T/$1"; git init -q "$d"; echo a > "$d/a.txt"
  git -C "$d" add -A; git -C "$d" commit -qm init; git -C "$d" checkout -q -b feat
  git -C "$d" remote add origin https://github.com/acme/widgets.git
  git -C "$d" remote add upstream https://github.com/public/widgets.git
  git -C "$d" remote set-url --push upstream DISABLED
  echo "$d"
}

r="$(mk base)"
out="$(run "$r")"
eq "origin is the default push remote: repo" "$(jq -r .repo <<<"$out")" acme/widgets
eq "origin is the default push remote: remote" "$(jq -r .remote <<<"$out")" origin
eq "exit 0" "$(rcof "$r")" 0

# tracking branch on the push-disabled remote, pushRemote says origin
r="$(mk pushremote)"; git -C "$r" config branch.feat.remote upstream; git -C "$r" config branch.feat.pushRemote origin
eq "branch pushRemote wins over the tracking remote" "$(jq -r .repo <<<"$(run "$r")")" acme/widgets

r="$(mk pushdefault)"; git -C "$r" config branch.feat.remote upstream; git -C "$r" config remote.pushDefault origin
eq "remote.pushDefault wins over the tracking remote" "$(jq -r .repo <<<"$(run "$r")")" acme/widgets

# push-disabled remote
r="$(mk disabled)"; git -C "$r" config branch.feat.remote upstream
out="$(run "$r")"
eq "push-disabled remote exits 2" "$(rcof "$r")" 2
eq "push-disabled remote error code" "$(jq -r .error <<<"$out")" push-disabled
eq "push-disabled remote has no repo" "$(jq -r 'has("repo")' <<<"$out")" false
eq "push-disabled remote names the remote" "$(jq -r .remote <<<"$out")" upstream
for sentinel in no_push no-push DISABLE disabled none off /dev/null; do
  r="$(mk "sent-${sentinel//\//_}")"; git -C "$r" remote set-url --push origin "$sentinel"
  eq "push URL '$sentinel' counts as disabled" "$(jq -r .error <<<"$(run "$r")")" push-disabled
done
r="$(mk notaurl)"; git -C "$r" remote set-url --push origin "some words here"
out="$(run "$r")"
eq "a push URL that is not a remote URL counts as disabled" "$(jq -r .error <<<"$out")" push-disabled
case "$(jq -r .message <<<"$out")" in *"not a remote URL"*"treated as disabled"*) ok "that refusal says so";; *) bad "refusal message" "$(jq -r .message <<<"$out")";; esac
r="$(mk localpath)"; git -C "$r" remote set-url --push origin ../elsewhere.git
eq "a relative path is a remote URL, just with no OWNER/REPO" "$(jq -r .error <<<"$(run "$r")")" unresolvable

# git-issue and git-pr resolve the repository with the helper and pass --repo to the calls that take it
skills="$(cd "$hooks/../skills" && pwd)"
for sk in git-issue git-pr; do
  f="$skills/$sk/SKILL.md"; verb="${sk#git-}"
  grep -q 'local-hooks/gh-repo.sh --dir' "$f" && ok "$sk runs gh-repo.sh" || bad "$sk runs gh-repo.sh"
  grep -q "gh $verb create --repo <OWNER/REPO>" "$f" && ok "$sk passes --repo to gh $verb create" || bad "$sk passes --repo to gh $verb create"
  grep -q 'repo-unresolved' "$f" && ok "$sk blocks when the repository cannot be resolved" || bad "$sk blocks when the repository cannot be resolved"
  grep -q 'gh auth status. and any `gh` command that takes no `--repo`' "$f" && ok "$sk exempts gh auth status from --repo" || bad "$sk exempts gh auth status from --repo"
done

# the tracking remote is used when it can be pushed to
r="$(mk tracking)"; git -C "$r" remote add fork git@github.com:me/widgets-fork.git; git -C "$r" config branch.feat.remote fork
eq "tracking remote (scp url)" "$(jq -r .repo <<<"$(run "$r")")" me/widgets-fork
eq "tracking remote name" "$(jq -r .remote <<<"$(run "$r")")" fork

# fallbacks to origin
r="$(mk dot)"; git -C "$r" config branch.feat.remote .
eq "branch remote '.' falls back to origin" "$(jq -r .repo <<<"$(run "$r")")" acme/widgets
r="$(mk detached)"; git -C "$r" checkout -q --detach
eq "detached head falls back to origin" "$(jq -r .repo <<<"$(run "$r")")" acme/widgets

# push URL beats fetch URL
r="$(mk pushurl)"; git -C "$r" remote set-url --push origin ssh://git@github.com/fork/widgets.git
eq "the push URL is the one resolved" "$(jq -r .repo <<<"$(run "$r")")" fork/widgets

# url spellings
r="$(mk spell)"
git -C "$r" remote set-url origin git@github.com:Acme/Widgets.git
eq "scp url keeps its case" "$(jq -r .repo <<<"$(run "$r")")" Acme/Widgets
git -C "$r" remote set-url origin https://user@github.com/acme/widgets/
eq "https url with user and trailing slash" "$(jq -r .repo <<<"$(run "$r")")" acme/widgets
git -C "$r" remote set-url origin git@git.example.test:team/app.git
eq "another host keeps the host" "$(jq -r .repo <<<"$(run "$r")")" git.example.test/team/app

# refusals
r="$(mk nolocal)"; git -C "$r" remote set-url origin /srv/only-one
out="$(run "$r")"
eq "url with no owner exits 2" "$(rcof "$r")" 2
eq "url with no owner error code" "$(jq -r .error <<<"$out")" unresolvable
r="$(mk noorigin)"; git -C "$r" remote remove origin
out="$(run "$r")"
eq "no origin and no configured remote: exit 2" "$(rcof "$r")" 2
eq "no origin and no configured remote: code" "$(jq -r .error <<<"$out")" no-remote
r="$T/bare-none"; git init -q "$r"
eq "repo with no remote: code" "$(jq -r .error <<<"$(run "$r")")" no-remote
r="$(mk missing)"; git -C "$r" config branch.feat.pushRemote nothere
eq "pushRemote naming a missing remote: code" "$(jq -r .error <<<"$(run "$r")")" no-remote
mkdir "$T/plain-dir"
out="$(run "$T/plain-dir")"
eq "non-repo exits 2" "$(rcof "$T/plain-dir")" 2
eq "non-repo error code" "$(jq -r .error <<<"$out")" not-a-repo
eq "bad argument exits 2" "$(bash "$script" --bogus >/dev/null 2>&1; echo $?)" 2
eq "--dir without value exits 2" "$(bash "$script" --dir >/dev/null 2>&1; echo $?)" 2

# read-only: no config change, no bytecode
pyc_before="$(find "$hooks" -name '__pycache__' | sort)"
r="$(mk readonly)"; before="$(git -C "$r" config --list | sha256sum)"
run "$r" >/dev/null
eq "config unchanged" "$(git -C "$r" config --list | sha256sum)" "$before"
# only directories this run created count (leftovers from other runs are not ours)
eq "no bytecode written" "$(comm -13 <(printf '%s\n' "$pyc_before") <(find "$hooks" -name '__pycache__' | sort) | wc -l | tr -d ' ')" 0

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
