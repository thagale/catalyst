#!/usr/bin/env bash
# audit-automerge-cascade.sh — detect, verify, and fix CAT-151 cascade suppression.
# Only --rollout --fix writes. Verification keys on PR mergedBy + exact merge SHA;
# commit.committer.name is GitHub in both the working and suppressed cases.
set -uo pipefail

GH="${CATALYST_AUTOMERGE_GH_BIN:-gh}"
MODE=audit REPOS_FILE="${AUTOMERGE_CASCADE_REPOS:-}" ORG="" JSON=0 FIX=0 PATCH_WRITE=1
SINCE="" SECRET_NAME=AUTOMERGE_PAT LIMIT=0 PATCH_FILE=""
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../templates/github-actions/auto-merge.yml.template"

usage() {
	cat <<'EOF'
Usage: audit-automerge-cascade.sh [--audit|--verify|--history|--rollout]
       [--repos FILE|--org ORG] [--since 7d|48h|ISO-DATE] [--json]
       [--secret-name NAME] [--dry-run|--fix] [--limit N]
       [--patch-workflow FILE] (offline patcher/test seam)
EOF
}
die() { echo "audit-automerge-cascade: $1" >&2; exit "${2:-2}"; }

while [[ $# -gt 0 ]]; do
	case "$1" in
	--audit) MODE=audit ;;
	--verify) MODE=verify ;;
	--history) MODE=history ;;
	--rollout) MODE=rollout ;;
	--repos) [[ $# -gt 1 ]] || die "--repos needs a file"; REPOS_FILE="$2"; shift ;;
	--org) [[ $# -gt 1 ]] || die "--org needs a name"; ORG="$2"; shift ;;
	--since) [[ $# -gt 1 ]] || die "--since needs a value"; SINCE="$2"; shift ;;
	--secret-name) [[ $# -gt 1 ]] || die "--secret-name needs a name"; SECRET_NAME="$2"; shift ;;
	--limit) [[ $# -gt 1 ]] || die "--limit needs a number"; LIMIT="$2"; shift ;;
	--patch-workflow) [[ $# -gt 1 ]] || die "--patch-workflow needs a file"; PATCH_FILE="$2"; shift ;;
	--json) JSON=1 ;;
	--fix) FIX=1; PATCH_WRITE=1 ;;
	--dry-run) FIX=0; PATCH_WRITE=0 ;;
	-h|--help) usage; exit 0 ;;
	*) die "unknown argument '$1'" ;;
	esac
	shift
done
[[ "$SECRET_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid secret name '$SECRET_NAME'"
[[ "$LIMIT" =~ ^[0-9]+$ ]] || die "--limit must be a non-negative integer"

render_template() {
	[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE" 3
	local marker
	for marker in 'AUTOMERGE_PAT:' 'FALLBACK_TOKEN:' '::warning title=Auto-merge cascade suppressed::' 'gh pr merge "$PR_URL" --auto --squash' 'contents: write' 'pull-requests: write'; do
		grep -qF "$marker" "$TEMPLATE" || die "template missing marker '$marker'" 3
	done
	sed "s/{{SECRET_NAME}}/${SECRET_NAME}/g" "$TEMPLATE"
}

patch_workflow() {
	local file="$1" tmp target env_line merge_line
	grep -qE 'gh[[:space:]]+pr[[:space:]]+merge' "$file" || { echo refused; return 3; }
	if grep -qF 'AUTOMERGE_PAT: ${{ secrets.' "$file" &&
		grep -qF '::warning title=Auto-merge cascade suppressed::' "$file"; then
		echo already-current
		return 0
	fi
	# The patcher preserves repository-specific workflow policy and only expands
	# an existing block-scalar merge command. Rewriting inline YAML safely would
	# require a YAML-aware editor; fail closed instead of emitting invalid YAML.
	target="$(merge_step_lines "$file")"
	[[ -n "$target" ]] || { echo refused; return 3; }
	read -r env_line merge_line <<<"$target"
	[[ -n "$env_line" && -n "$merge_line" ]] || { echo refused; return 3; }
	tmp="$(mktemp "${TMPDIR:-/tmp}/automerge-template.XXXXXX")" || return 3
	# Modify only the merge step. Repository-specific triggers, authorization
	# gates, dependencies, permissions, and adjacent steps are security policy.
	awk -v secret="$SECRET_NAME" -v env_line="$env_line" -v merge_line="$merge_line" '
		NR == env_line {
			match($0, /^[[:space:]]*/); indent=substr($0, 1, RLENGTH)
			print indent "# CAT-151: GITHUB_TOKEN merges do not start downstream workflows."
			print indent "AUTOMERGE_PAT: ${{ secrets." secret " }}"
			print indent "FALLBACK_TOKEN: ${{ secrets.GITHUB_TOKEN }}"
			next
		}
		NR == merge_line {
			match($0, /^[[:space:]]*/); indent=substr($0, 1, RLENGTH); cmd=$0; sub(/^[[:space:]]*/, "", cmd)
			print indent "set -euo pipefail"
			print indent "if [ -n \"${AUTOMERGE_PAT}\" ]; then"
			print indent "  export GH_TOKEN=\"${AUTOMERGE_PAT}\""
			print indent "else"
			print indent "  echo \"::warning title=Auto-merge cascade suppressed::" secret " is not available to this run; merging with GITHUB_TOKEN. Downstream push / workflow_run pipelines will NOT fire (CAT-151).\""
			print indent "  export GH_TOKEN=\"${FALLBACK_TOKEN}\""
			print indent "fi"
			print indent cmd
			next
		}
		{print}
	' "$file" >"$tmp"
	if ! validate_yaml "$tmp"; then rm -f "$tmp"; echo refused; return 3; fi
	if cmp -s "$file" "$tmp"; then rm -f "$tmp"; echo already-current; return 0; fi
	if [[ $FIX -eq 1 || ( -n "$PATCH_FILE" && $PATCH_WRITE -eq 1 ) ]]; then mv "$tmp" "$file"; echo patched; else diff -u "$file" "$tmp" || true; rm -f "$tmp"; echo would-patch; fi
}

validate_yaml() {
	local file="$1"
	if python3 -c 'import yaml' >/dev/null 2>&1; then
		python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$file" >/dev/null 2>&1
	elif command -v ruby >/dev/null 2>&1; then
		ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$file" >/dev/null 2>&1
	else
		echo "audit-automerge-cascade: no YAML parser available (python3/PyYAML or ruby required)" >&2
		return 1
	fi
}

# Print the GH_TOKEN and merge-command line numbers for the one literal-block
# run step that performs auto-merge. Comments and non-literal scalars cannot
# become patch targets.
merge_step_lines() {
	awk '
		{ lines[NR]=$0 }
		END {
			for (i=1; i<=NR; i++) {
				line=lines[i]; code=line; sub(/[[:space:]]*#.*/, "", code)
				if (code !~ /^[[:space:]]*run:[[:space:]]*\|[-+]?[[:space:]]*$/) continue
				match(line, /^[[:space:]]*/); run_indent=RLENGTH
				merge=0
				for (j=i+1; j<=NR; j++) {
					match(lines[j], /^[[:space:]]*/); indent=RLENGTH
					if (lines[j] !~ /^[[:space:]]*$/ && indent <= run_indent) break
					body=lines[j]; sub(/[[:space:]]*#.*/, "", body)
					if (body ~ /gh[[:space:]]+pr[[:space:]]+merge/) { merge=j; break }
				}
				if (!merge) continue
				step=1
				for (j=i-1; j>=1; j--) if (lines[j] ~ /^[[:space:]]*-[[:space:]]/) { step=j; break }
				env=0
				for (j=step; j<i; j++) if (lines[j] ~ /GH_TOKEN:[[:space:]]*\$\{\{[[:space:]]*secrets\.GITHUB_TOKEN[[:space:]]*\}\}/) env=j
				if (env) { print env, merge; exit }
			}
		}
	' "$1"
}

if [[ -n "$PATCH_FILE" ]]; then
	[[ -f "$PATCH_FILE" ]] || die "workflow not found: $PATCH_FILE" 3
	patch_workflow "$PATCH_FILE"
	exit $?
fi

since_iso() {
	local raw="$1" n unit epoch
	if [[ "$raw" =~ ^([0-9]+)([dh])$ ]]; then
		n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"; [[ "$n" -gt 0 ]] || return 1
		[[ "$unit" == d ]] && n=$((n * 24))
		epoch=$(( $(date +%s) - n * 3600 ))
		date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
	elif [[ "$raw" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$ ]]; then
		[[ "$raw" == *T* ]] && printf '%s\n' "$raw" || printf '%sT00:00:00Z\n' "$raw"
	else return 1
	fi
}

load_repos() {
	if [[ -n "$REPOS_FILE" ]]; then
		[[ -r "$REPOS_FILE" ]] || die "repo list not readable: $REPOS_FILE"
		jq -r 'if type=="object" then keys[] elif type=="array" then .[] | if type=="object" then .repo else . end else empty end' "$REPOS_FILE" 2>/dev/null || die "invalid repo JSON: $REPOS_FILE"
	elif [[ -n "$ORG" ]]; then
		"$GH" repo list "$ORG" --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner' || die "repo enumeration failed" 5
	else
		local default="${HOME}/.config/catalyst/automerge-cascade-repos.json"
		[[ -r "$default" ]] || die "no repositories: pass --repos/--org or create $default"
		REPOS_FILE="$default"; load_repos
	fi
}

workflow_body() {
	local repo="$1" file="$2" encoded
	encoded="$("$GH" api "repos/${repo}/contents/.github/workflows/${file}" --jq '.content' 2>/dev/null)" || return 1
	printf '%s' "$encoded" | tr -d '\n' | base64 -d 2>/dev/null
}

merge_step_token() {
	awk '
		/^[[:space:]]*-[[:space:]]/ { token="" }
		/GH_TOKEN:[[:space:]]*\$\{\{[[:space:]]*secrets\.[A-Za-z0-9_]+[[:space:]]*\}\}/ {
			x=$0; sub(/^.*secrets\./,"",x); sub(/[[:space:]]*\}\}.*$/,"",x); token="secrets." x
		}
		{
			code=$0; sub(/[[:space:]]*#.*/, "", code)
			if (code ~ /gh[[:space:]]+pr[[:space:]]+merge/) { print token; exit }
		}
	'
}

pipeline_kind() {
	local repo="$1" list path body found=none
	list="$("$GH" api "repos/${repo}/contents/.github/workflows" --jq '.[].path' 2>/dev/null)" || { echo unknown; return; }
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		body="$(workflow_body "$repo" "${path##*/}" 2>/dev/null || true)"
		if grep -qE 'workflow_run:' <<<"$body"; then found=workflow_run
		elif [[ "$found" == none ]] && grep -qE '^[[:space:]]*push:' <<<"$body" && grep -qE 'main' <<<"$body"; then found=push; fi
	done <<<"$list"
	echo "$found"
}

classify_repo() {
	local repo="$1" file="" body="" token="" status pipelines listing
	if ! listing="$("$GH" api "repos/${repo}/contents/.github/workflows" --jq '.[].path' 2>/dev/null)"; then
		printf '%s\t\t\tunknown\tunknown\n' "$repo"
		return
	fi
	for candidate in auto-merge.yml auto-merge-own-prs.yml; do
		grep -qxF ".github/workflows/$candidate" <<<"$listing" || continue
		if body="$(workflow_body "$repo" "$candidate")"; then file="$candidate"; break
		else printf '%s\t%s\t\tunknown\tunknown\n' "$repo" "$candidate"; return
		fi
	done
	if [[ -z "$file" ]]; then printf '%s\t\t\tnot-applicable\tnone\n' "$repo"; return; fi
	token="$(merge_step_token <<<"$body")"
	pipelines="$(pipeline_kind "$repo")"
	case "$token" in
	secrets.GITHUB_TOKEN) [[ "$pipelines" == none ]] && status=suppressed-inert || status=suppressed ;;
	secrets.*) status=ok ;;
	*) status=unknown ;;
	esac
	printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$file" "$token" "$status" "$pipelines"
}

emit_audit() {
	local rows="$1"
	if [[ $JSON -eq 1 ]]; then
		printf '%s\n' "$rows" | jq -Rsc 'split("\n") | map(select(length>0) | split("\t") | {repo:.[0],file:.[1],token:.[2],status:.[3],pipelines:.[4]})'
	else printf '%s\n' "$rows"; fi
}

verify_repo() {
	local repo="$1" cutoff="$2" prs runs pr sha by num verdict
	prs="$("$GH" pr list --repo "$repo" --state merged --limit 1000 --json number,mergedAt,mergedBy,mergeCommit 2>/dev/null)" || { printf '%s\t\tunknown\tunknown\n' "$repo"; return; }
	runs="$("$GH" run list --repo "$repo" --event push --branch main --limit 1000 --json headSha 2>/dev/null)" || { printf '%s\t\tunknown\tunknown\n' "$repo"; return; }
	jq -c --arg since "$cutoff" '.[] | select(.mergedAt >= $since)' <<<"$prs" 2>/dev/null | while IFS= read -r pr; do
		sha="$(jq -r '.mergeCommit.oid // empty' <<<"$pr")"; by="$(jq -r '.mergedBy.login // "unknown"' <<<"$pr")"; num="$(jq -r .number <<<"$pr")"
		if jq -e --arg sha "$sha" 'any(.[]; .headSha == $sha)' <<<"$runs" >/dev/null 2>&1; then verdict=cascaded; else verdict=suppressed; fi
		printf '%s\t#%s\t%s\t%s\t%s\n' "$repo" "$num" "$by" "$verdict" "$sha"
	done
}

rollout_repo() {
	local repo="$1" file="$2" status="$3" scratch branch marker open clone_url result
	[[ "$status" == suppressed || "$status" == suppressed-inert ]] || { echo "$repo: skipped ($status)"; return 0; }
	marker='<!-- catalyst:cat-151-automerge-cascade -->'
	open="$("$GH" pr list --repo "$repo" --state open --search 'cat-151-automerge-cascade' --json body --jq '.[].body' 2>/dev/null || true)"
	grep -qF "$marker" <<<"$open" && { echo "$repo: already-open"; return 0; }
	if [[ $FIX -eq 0 ]]; then
		scratch="$(mktemp -d "${TMPDIR:-/tmp}/automerge-dry-run.XXXXXX")" || return 1
		workflow_body "$repo" "$file" >"$scratch/$file" || { rm -rf "$scratch"; return 1; }
		echo "$repo: dry-run diff for .github/workflows/$file"
		patch_workflow "$scratch/$file"
		rm -rf "$scratch"
		return 0
	fi
	scratch="$(mktemp -d "${TMPDIR:-/tmp}/automerge-rollout.XXXXXX")" || return 1
	clone_url="$("$GH" repo view "$repo" --json url --jq .url 2>/dev/null || true)"; [[ -n "$clone_url" ]] || clone_url="https://github.com/${repo}.git"
	if ! git clone -q --depth 1 "$clone_url" "$scratch/repo"; then echo "$repo: failed (clone)"; rm -rf "$scratch"; return 1; fi
	branch=catalyst/cat-151-automerge-cascade
	git -C "$scratch/repo" checkout -q -b "$branch"
	result="$(FIX=1 patch_workflow "$scratch/repo/.github/workflows/$file")" || { echo "$repo: failed (patch)"; rm -rf "$scratch"; return 1; }
	if [[ "$result" == already-current ]]; then echo "$repo: already-current"; rm -rf "$scratch"; return 0; fi
	git -C "$scratch/repo" add ".github/workflows/$file"
	git -C "$scratch/repo" -c user.name=catalyst -c user.email=catalyst@localhost -c commit.gpgsign=false commit -q -m 'fix(ci): restore post-merge cascade (CAT-151)' || { rm -rf "$scratch"; return 1; }
	git -C "$scratch/repo" push -q -u origin "$branch" || { echo "$repo: failed (push)"; rm -rf "$scratch"; return 1; }
	"$GH" pr create --repo "$repo" --head "$branch" --base main --title 'fix(ci): restore post-merge cascade (CAT-151)' --body "$(printf '%s\n\n%s\n\n%s' "$marker" 'Use a PAT identity for auto-merge so push CI and workflow_run deploys cascade.' 'Falls back to GITHUB_TOKEN with a warning when the secret is unavailable.')" >/dev/null || { echo "$repo: failed (pr create)"; rm -rf "$scratch"; return 1; }
	echo "$repo: opened"; rm -rf "$scratch"
}

REPOS=()
while IFS= read -r repo_entry; do
	[[ -n "$repo_entry" ]] && REPOS+=("$repo_entry")
done < <(load_repos)
[[ ${#REPOS[@]} -gt 0 ]] || die "repository list is empty"

case "$MODE" in
audit)
	ROWS=""; bad=0 unknown=0
	for repo in "${REPOS[@]}"; do row="$(classify_repo "$repo")"; ROWS+="${row}"$'\n'; grep -q $'\tsuppressed' <<<"$row" && bad=1; grep -q $'\tunknown\t' <<<"$row" && unknown=1; done
	emit_audit "$ROWS"; [[ $bad -eq 1 ]] && exit 10; [[ $unknown -eq 1 ]] && exit 5; exit 0 ;;
verify|history)
	[[ -n "$SINCE" ]] || { [[ "$MODE" == history ]] && SINCE=90d || SINCE=7d; }
	CUTOFF="$(since_iso "$SINCE")" || die "invalid --since value '$SINCE'"
	bad=0 unknown=0
	for repo in "${REPOS[@]}"; do
		rows="$(verify_repo "$repo" "$CUTOFF")"
		if [[ "$MODE" == history ]]; then filtered="$(grep $'\tsuppressed\t' <<<"$rows" || true)"; [[ -n "$filtered" ]] && printf '%s\n' "$filtered"; count="$(grep -c $'\tsuppressed\t' <<<"$rows" || true)"; echo "$repo: $count merges never deployed"; else [[ -n "$rows" ]] && printf '%s\n' "$rows" || printf '%s\t\tno-merges\tno-merges\n' "$repo"; fi
		grep -q $'\tsuppressed\t' <<<"$rows" && bad=1
		grep -q $'\tunknown\t' <<<"$rows" && unknown=1
	done
	[[ $bad -eq 1 ]] && exit 10; [[ $unknown -eq 1 ]] && exit 5; exit 0 ;;
rollout)
	bad=0 touched=0
	for repo in "${REPOS[@]}"; do
		row="$(classify_repo "$repo")"; IFS=$'\t' read -r _ file _ status _ <<<"$row"
		if [[ "$status" == suppressed || "$status" == suppressed-inert ]]; then
			if [[ $LIMIT -gt 0 && $touched -ge $LIMIT ]]; then echo "$repo: skipped (--limit $LIMIT)"; continue; fi
			touched=$((touched+1))
		fi
		rollout_repo "$repo" "$file" "$status" || bad=1
	done
	[[ $bad -eq 1 ]] && exit 5; exit 0 ;;
esac
