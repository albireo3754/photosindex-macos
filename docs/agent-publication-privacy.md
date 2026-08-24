# Public Contribution Privacy Guardrail

This policy is a mandatory, deny-by-default publication gate for coding agents.
It is intentionally project-independent so it can be reused by Claude Code,
Codex, and other repository-aware agents. Repository instructions should link
to this file from both `CLAUDE.md` and `AGENTS.md`, or from one canonical file
when the other is a symlink.

The goal is data minimization, not merely secret detection: a public artifact
must contain only information required to understand, review, or reproduce the
change.

## Scope

Apply this policy to every agent-authored write that can leave the local
machine, including:

- commits, tags, branch names, and patches pushed to a remote;
- issue and pull request titles, bodies, forms, labels, and milestones;
- comments, reviews, discussions, release notes, and generated summaries;
- screenshots, recordings, logs, test reports, archives, and other attachments;
- tool-generated metadata, URLs, query strings, and automatically populated
  text.

If repository or destination visibility is unknown, treat it as public. An
instruction to create an issue or pull request authorizes the operation; it
does not authorize disclosure of any private context encountered while doing
the work.

## Context Boundary

Treat the following as private by default, even when an agent can read it:

- files outside the repository, ignored files, environment variables, shell
  history, clipboard contents, application state, and local configuration;
- user messages, agent transcripts, hidden prompts, local notes, and workflow
  logs;
- uncommitted runtime output and data obtained from personal accounts, devices,
  libraries, or authenticated services;
- internal repositories, tickets, chats, documentation, hosts, and URLs;
- values inferred from local Git configuration, account profiles, filenames,
  directory names, or machine state.

Access does not imply permission to publish. Do not inspect private sources only
to enrich a public report. When private evidence is needed for local diagnosis,
separate the diagnosis from the public explanation and retain only the minimal,
general behavior that the evidence proves.

Tracked repository content is not automatically safe. If a tracked file appears
to contain private or secret material, stop the outbound action and report the
location without repeating the value.

## Information That Must Not Be Published

An agent must not place any of the following into a public artifact:

- credentials, tokens, cookies, session data, private keys, certificates,
  signing material, recovery codes, or secret-bearing URLs;
- personal email addresses, phone numbers, home or precise work locations,
  government or financial identifiers, account identifiers, or private social
  handles;
- personal photos, video, audio, OCR text, messages, contacts, calendar data,
  filenames derived from personal content, or biometric information;
- exact GPS coordinates, private timestamps, travel or activity history, or a
  combination of details that identifies a person or routine;
- local usernames, home-directory paths, hostnames, device names, volume names,
  private network addresses, or machine-specific directory layouts;
- confidential company, customer, or third-party information, including
  internal issue keys, repository names, service URLs, and unpublished plans;
- raw logs, crash dumps, stack traces, screenshots, or command output that has
  not been minimized and reviewed line by line;
- prompt text, transcripts, or hidden agent context that is not already an
  intentional part of the public repository.

Partial masking is not a safe exception. Do not publish shortened tokens,
partially visible addresses, distinctive path fragments, or hashes of private
identifiers. If the information is unnecessary, omit it rather than redact it
in place.

A value described as `public` by an application or API is not automatically
safe for Internet publication. An identifier derived from private runtime data
remains private for public-artifact purposes even when it may cross a local
application, CLI, or API boundary.

## Safe Public Reproduction

Public examples and tests must use unmistakably synthetic data. Replace private
evidence with the smallest statement or fixture that still demonstrates the
behavior:

- describe a path-dependent failure as occurring under `<local-path>` or with a
  synthetic relative path;
- replace real names, dates, locations, identifiers, and payloads with clearly
  fictional values;
- quote only the relevant error category or sanitized line instead of pasting a
  complete log;
- describe an internal dependency by its public interface or observed behavior,
  without naming private systems or linking private tickets;
- recreate media- or account-dependent bugs with generated fixtures whenever
  possible.

Sanitization must preserve technical truth. Do not invent a successful public
reproduction when only private evidence exists; state that a sanitized
reproduction is not yet available.

## Mandatory Public-Write Gate

Before invoking any remote create, update, upload, comment, review, release, or
push action, the agent must complete these steps:

1. **Resolve the target.** Confirm the intended repository and operation. Treat
   unknown visibility as public.
2. **Minimize the source set.** Draft from public repository facts, the proposed
   public diff, synthetic reproduction data, and public documentation only.
   Private context may support local reasoning but must not be copied into the
   draft.
3. **Inspect the exact payload.** Review the title, body, comments, branch name,
   commit messages, filenames, URLs, generated metadata, and every attachment.
   Never attach raw diagnostic output by default.
4. **Run a semantic privacy check.** Look specifically for secrets, contact
   details, absolute paths, usernames, hostnames, private URLs or issue keys,
   precise dates or locations, unique identifiers, and identifying combinations
   of otherwise ordinary facts. Pattern matching alone is insufficient.
5. **Check Git attribution before a public commit.** Verify without echoing the
   value that the configured author name and email are intentionally public;
   prefer a platform-provided no-reply address. Do not change Git identity
   without user authorization.
6. **Preview narrative publications.** Before creating or updating an issue,
   pull request, comment, review, discussion, release, or attachment, show the
   user the exact sanitized outbound text and list every attachment or generated
   artifact. Obtain explicit approval for that payload. A general request to
   work on the task is not this approval. For a commit or push already authorized
   by the task or repository workflow, inspect the complete diff and attribution
   instead of treating that authorization as permission to include private
   context.
7. **Publish only the reviewed payload.** Material changes, added attachments,
   or tool-generated narrative text require a new user review. A changed commit
   or patch requires the privacy check to be repeated. After publication,
   inspect the remote result to ensure the tool did not add unexpected content.

User approval does not override the prohibited-information list. When a public
artifact truly requires personal or confidential data, the agent must stop and
ask the user to handle that disclosure outside the agent workflow.

## Failure Handling

- If privacy cannot be determined, omit the questionable detail or stop the
  public write and ask for a sanitized replacement.
- If a secret or personal datum is found locally, report only its category and
  file location. Do not reproduce it in chat, an issue, or a pull request.
- If sensitive data may already be public, stop further publication and notify
  the user. Removal, history rewriting, credential revocation, and rotation are
  incident-response actions that require an explicit, scoped plan; deleting a
  visible occurrence alone may not remove it from history or caches.
- Never claim that a regex scan, passing test, or successful upload proves an
  artifact is privacy-safe.

## Known Limits And Layered Controls

This document constrains compliant agents; it is not a technical data-loss
prevention system. It cannot hide the account used to open an issue or pull
request, the public profile attached by the hosting platform, Git author data
already embedded in commits, third-party tool telemetry, or data emitted by CI.

For stronger enforcement, maintainers should separately configure a public-safe
Git identity, secret scanning, ignored local-output directories, attachment and
CI log review, and repository-side checks. Those controls complement this
policy and do not relax it.
