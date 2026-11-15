# Herdr Core Requester Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SSH and Run prompts whose requester runs in a Herdr Core terminal show `program · terminal name/title` and the current folder, with Herdr.app's icon when it is installed and verified.

**Architecture:** A pure resolver recognizes a Core-hosted request from the identified client (`dev.herdr.core`), the captured process chain and a new `HC_TERMINAL_ID`/`HC_TERMINAL_SOCKET` routing hint. A Core provider then does three things in one call under one 750 ms deadline. It verifies the running holder's code signature. It queries the hinted Core socket directly with JSON-RPC `terminal.get`, after verifying the socket peer's audit token against the Core signing requirement, so no binary is executed. And it proves ownership: the terminal's `pid` must be the chain's terminal root, whose parent is the holder. `RequesterHeaderModel` gains a Core branch next to the classic Herdr branch. Classic Herdr code paths are untouched.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI/AppKit, Security.framework (`SecCode`, `SecStaticCode`, audit tokens), Darwin sockets/`proc_pidinfo`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-12-herdr-core-requester-context-design.md`

## Global Constraints

- Core bundle ID `dev.herdr.core`; Herdr.app bundle ID `dev.herdr.app`; team `2W9652Q7QR`.
- Requirement strings (exact):
  - Core: `identifier "dev.herdr.core" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2W9652Q7QR"`
  - App: `identifier "dev.herdr.app" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2W9652Q7QR"`
- Dynamic checks (holder by pid, socket peer by audit token) use `SecCodeCheckValidity(code, [.strictValidate]…)`. The Herdr.app static check is icon-only: `SecStaticCodeCheckValidity` with `[.doNotValidateResources]`, cached per app URL + file inode + modification date.
- One absolute **750 ms** deadline per displayed prompt, owned by the provider's injected `now`. Socket replies are capped at **512 KiB**. The only request sent is `{"jsonrpc":"2.0","id":1,"method":"terminal.get","params":{"terminal":"<address>"}}\n`, a read-only method. Verified live: there's no handshake, it answers in under 1 ms, and errors come back as `{"error":{…}}`.
- Hinted socket: absolute path, shorter than `sun_path`, a socket owned by `getuid()` (reuse `HerdrSocketIdentity.read`), identity unchanged after the reply, and peer verified as Core. Any session's socket qualifies, not only `default`.
- Routing hint fields: `HC_TERMINAL_ID=`, `HC_TERMINAL_SOCKET=`. Each must be UTF-8, non-empty, ≤4096 bytes, free of control characters and not duplicated; the socket path must be absolute. Nothing else from the environment is retained. A malformed `HC_*` value never affects the Herdr hint on the same node, and vice versa.
- Title/name/`bundleIdentifier`/`bundleURL`/`showCommand`/cache keys/Run scope never change. Core text is untrusted: sanitize with `HerdrMetadataDecoder.sanitize(_:homeDirectory:)`.
- Nothing persisted or logged; no raw reply or error retained.
- No Settings entry; Core enrichment is automatic and ignores `TerminalHostStore` changes. Classic Herdr behavior and tests unchanged.
- New strings in `Quick Access for Pass/Resources/Localizable.xcstrings` with English, Czech and translator context.
- Swift Testing only. Commits are GPG-signed with no `Co-Authored-By` trailer (repo owner rule).

## Review Focus

1. **Socket peer is not Core** (another same-user process listening at the hinted path) → nothing is sent beyond the connect, and there are no details. Test in Task 5.
2. **Hostile terminal name/title** (ANSI escapes, newlines, 10 KB) → sanitized, ≤256 chars. Test in Task 3.
3. **Core restarted or updated while the prompt is open** (socket identity changes, reply missing, or connection reset) → no detail rows, and the lookup returns before the deadline. Test in Task 5.
4. **Requester reparented away from the holder** (chain ends at launchd) → no match, today's header. Test in Task 2.
5. **Herdr.app present but wrong team, or a slow signature check** → `terminal` symbol, details still shown within the deadline. Tests in Tasks 4 and 5.

## Commands

- Build: `xcodebuild -scheme "Quick Access for Pass" -configuration Debug build`
- One suite: `xcodebuild -scheme "Quick Access for Pass" test -only-testing:"Quick Access for Pass Tests/<Suite>"`
- All tests: `xcodebuild -scheme "Quick Access for Pass" test`
- Localization: per `CONTRIBUTING.md` (`scripts/verify-localizations.py --catalog … --stringsdata-root … --app …` plus fixture tests).

---

### Task 1: Capture the Core routing hint

**Files:**
- Modify: `Quick Access for Pass/Models/RequesterProcessSnapshot.swift`
- Modify: `Quick Access for Pass/Services/TerminalHosts/RequesterProcessCapture.swift`
- Test: `Quick Access for Pass Tests/RequesterProcessSnapshotTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated struct HerdrCoreRoutingHint: Equatable, Sendable {
      let terminalID: String
      let socketPath: String
      let originatingPID: pid_t
      let originatingStartTimeMicroseconds: UInt64
  }
  // RequesterProcessSnapshot gains (defaulted so existing initializers compile):
  var coreRoutingHints: [HerdrCoreRoutingHint] = []
  // RequesterProcessCapture:
  static func decodeCoreRoutingHint(_ data: Data, pid: pid_t, startTimeMicroseconds: UInt64) -> HerdrCoreRoutingHint?
  ```

- [ ] **Step 1: Write failing tests** (reuse the file's procargs fixture builder):
  - `coreHintDecodesTerminalAndSocket`: env `HC_TERMINAL_ID=t5`, `HC_TERMINAL_SOCKET=/Users/u/.local/state/herdr-core/default/default.sock`, `HC_SCOPE=x`, `PATH=/bin` → exact hint (pid 7, start 9).
  - `coreHintRejectsInvalidValues` (arguments): missing ID; missing socket; relative socket; empty value; duplicate `HC_TERMINAL_ID`; value containing `\u{1b}`; 4097-byte value → `nil`.
  - `productsDecodeIndependently` (arguments: bad HC + good HERDR, good HC + bad HERDR on the same node) → the valid product's hint decodes, the invalid one is `nil`.
  - `captureCollectsCoreHintsIndependentlyOfHerdr`: node 2 has only HC vars, node 3 only HERDR vars → one hint each.
- [ ] **Step 2: Run** `-only-testing:"Quick Access for Pass Tests/RequesterProcessSnapshotTests"` → FAIL.
- [ ] **Step 3: Implement.** Extract the argv-skipping walk into a private helper that returns the environment field slices. Each decoder applies its own allowlist and validation to those fields, so validation never couples the two. Existing Herdr tests must stay green unchanged. `capture` decodes both from the same `readArguments` data.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(terminal-hosts): capture Herdr Core routing hints`

### Task 2: Recognize a Core-hosted request (pure)

**Files:**
- Create: `Quick Access for Pass/Services/TerminalHosts/HerdrCoreTerminalResolver.swift`
- Modify: `Quick Access for Pass/Services/SSHAgent/ProcessIdentifier.swift` (`shellNames` → internal `static let`)
- Test: `Quick Access for Pass Tests/HerdrCoreTerminalResolverTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces:
  ```swift
  nonisolated struct HerdrCoreTerminalMatch: Equatable, Sendable {
      let holder: RequesterProcessSnapshot.ProcessNode
      let terminalRoot: RequesterProcessSnapshot.ProcessNode
      /// Requester first, terminal root last.
      let requesterSideNodes: [RequesterProcessSnapshot.ProcessNode]
      let hint: HerdrCoreRoutingHint
      /// Topmost non-shell node below the holder; never the requester (index 0).
      let programNode: RequesterProcessSnapshot.ProcessNode?
  }
  nonisolated enum HerdrCoreTerminalResolver {
      static let coreBundleIdentifier = "dev.herdr.core"
      static func match(clientInfo: SSHClientInfo, snapshot: RequesterProcessSnapshot?) -> HerdrCoreTerminalMatch?
  }
  ```

Rules (no filesystem access; safe on the main actor):
1. `clientInfo.bundleIdentifier == "dev.herdr.core"` and `clientInfo.bundleURL != nil`, else `nil`.
2. Chain = `[requester] + ancestors.prefix(10)`. Holder = the nearest node at index ≥ 1 whose `executablePath` starts with `bundleURL.standardizedFileURL.path + "/"`. That is the same string `findAppBundle` walked, so no symlinks are resolved. None → `nil`.
3. Root = node at `holderIndex - 1`; require `root.parentPID == holder.pid`.
4. Core hints whose originating PID **and** start time match a node below the holder; none → `nil`; all must agree on `terminalID` and `socketPath`, else `nil`.
5. Program: walk from root (index `holderIndex-1`) towards index 1, picking the first node whose `(executablePath as NSString).lastPathComponent` (leading `-` stripped) is not in `ProcessIdentifier.shellNames`. None → `nil`.

- [ ] **Step 1: Write failing tests** (`node(pid, path)` helper; bundle `/U/.local/share/herdr-core/active/Herdr Core.app`; holder `…/Herdr Core.app/Contents/MacOS/herdr-core`):
  - `agentUnderShellIsProgram`: `ssh(10) ← git(11) ← zsh(12) ← claude(13) ← zsh(14) ← holder(15)`, hint on 13 → root 14, program 13, `requesterSideNodes` pids `[10,11,12,13,14]`.
  - `nonShellRootIsProgram`: `ssh(10) ← claude(11) ← holder(12)` → program 11.
  - `requesterIsNeverProgram`: `qa-run(10) ← zsh(11) ← holder(12)` → match, `programNode == nil`.
  - `loginShellDashIsShell`: root path `/bin/-zsh`-style last component `-zsh` → shell.
  - `rejects` (arguments): non-Core bundle ID; nil bundleURL; no holder (**Review Focus 4**: `ssh(10) ← zsh(11)`, `zsh.parentPID == 1`); root parent ≠ holder; no core hint; hint start-time mismatch; hint originating at or above the holder; two hints with different terminal IDs → `nil`.
  - `classicHerdrHintIgnored`: Core client with only a `HerdrRoutingHint` → `nil`.
- [ ] **Step 2: Run** `-only-testing:"Quick Access for Pass Tests/HerdrCoreTerminalResolverTests"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `RequesterPresentationResolverTests` → PASS.
- [ ] **Step 5: Commit** `feat(terminal-hosts): recognize Herdr Core terminal requesters`

### Task 3: Decode `terminal.get` and build sanitized details

**Files:**
- Create: `Quick Access for Pass/Models/HerdrCoreTerminalDetails.swift`
- Create: `Quick Access for Pass/Services/TerminalHosts/HerdrCoreTerminalDecoder.swift`
- Test: `Quick Access for Pass Tests/HerdrCoreTerminalDecoderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated struct HerdrCoreTerminalDetails: Equatable, Sendable {
      let programName: String?
      let terminalLabel: String?
      let workingDirectory: String?
  }
  nonisolated enum HerdrCoreTerminalDecoder {
      nonisolated struct Terminal: Equatable, Sendable {
          let address: String; let name: String?; let title: String?; let pid: pid_t; let state: String
      }
      /// Decodes one JSON-RPC response line; requires `"id": 1` and a `result` object. `error` or a missing field throws.
      static func terminal(fromResponse data: Data) throws -> Terminal
      static func details(program: String?, terminal: Terminal, workingDirectory: String?, homeDirectory: String) -> HerdrCoreTerminalDetails?
  }
  ```
  `details` sanitizes all three; label = sanitized `name` ?? sanitized `title`; `nil` when all three are `nil`.

- [ ] **Step 1: Write failing tests.** Fixtures copy the live shape `{"jsonrpc":"2.0","id":1,"result":{"address":"t5","name":null,"title":"Herdr core documentation","pid":71479,"state":"live","cwd":"/x","foreground":{…},"labels":{…},"unknown_field":{"x":1}}}`:
  - `decodesLiveUnnamedTerminal` → `Terminal(address: "t5", name: nil, title: "Herdr core documentation", pid: 71479, state: "live")`.
  - `nameWinsOverTitle` → label `"review"`.
  - `invalidResponsesThrow` (arguments): error object (`{"error":{"code":-32000,"data":{"kind":"not_found"},"message":"no terminal"},"id":1,"jsonrpc":"2.0"}`); wrong `id`; no `address`; no `pid`; `pid` as string; not JSON.
  - `hostileTitleIsSanitized` (**Review Focus 2**): `"\u{1b}[31mBuild\u{1b}[0m\nnext" + 10_000 × "x"` → no `\u{1b}`, no `\n`, `count <= 256`.
  - `homeIsAbbreviated`: `/Users/u/Code/p` with home `/Users/u` → `~/Code/p`.
  - `allEmptyIsNil`.
- [ ] **Step 2: Run** `-only-testing:"Quick Access for Pass Tests/HerdrCoreTerminalDecoderTests"` → FAIL.
- [ ] **Step 3: Implement** with `Decodable` (snake_case keys); unknown fields ignored.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(terminal-hosts): decode Herdr Core terminal metadata`

### Task 4: Signature verification and working-directory read

**Files:**
- Create: `Quick Access for Pass/Services/TerminalHosts/HerdrCodeSignatureVerifier.swift`
- Modify: `Quick Access for Pass/Services/TerminalHosts/RequesterProcessCapture.swift` (add `readWorkingDirectory`)
- Test: `Quick Access for Pass Tests/HerdrCodeSignatureVerifierTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated protocol HerdrCodeSignatureVerifying: Sendable {
      func isVerifiedCore(pid: pid_t) -> Bool
      func isVerifiedCore(auditToken: audit_token_t) -> Bool
      /// Installed Herdr.app whose static signature satisfies the app requirement; cached per URL+inode+mtime.
      func verifiedHerdrAppURL() -> URL?
  }
  nonisolated final class LiveHerdrCodeSignatureVerifier: HerdrCodeSignatureVerifying, @unchecked Sendable {
      static let coreRequirement: String  // exact Global Constraints string
      static let appRequirement: String
      init(coreRequirement: String = coreRequirement, appRequirement: String = appRequirement,
           locateApp: @escaping @Sendable () -> URL? = { LSCopyApplicationURLsForBundleIdentifier("dev.herdr.app" as CFString, nil)… first })
  }
  // RequesterProcessCapture:
  static func readWorkingDirectory(_ pid: pid_t) -> String?   // proc_pidinfo PROC_PIDVNODEPATHINFO → pvi_cdir
  ```
  - The pid and audit-token checks follow `PeerVerifier.verify(fd:)`: `SecCodeCopyGuestWithAttributes` with `kSecGuestAttributePid` or `kSecGuestAttributeAudit`, then `SecCodeCheckValidity(code, [.strictValidate], requirement)`.
  - The app check uses `SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity(code, [.doNotValidateResources], requirement)`.
  - The app verdict cache is guarded by an `OSAllocatedUnfairLock`, which justifies the `@unchecked Sendable`.
  - `LaunchServices` is used instead of `NSWorkspace` because the verifier runs off the main actor.

- [ ] **Step 1: Write failing tests:**
  - `currentTestProcessIsNotCore`: `isVerifiedCore(pid: getpid()) == false`; `nonexistentPIDIsNotCore` (`Int32.max`).
  - `teamClauseIsEnforced` (**Review Focus 5**): verifier with `appRequirement: #"identifier "com.apple.calculator" and anchor apple generic and certificate leaf[subject.OU] = "2W9652Q7QR""#` and `locateApp: { /System/Applications/Calculator.app }` → `nil`. With `appRequirement: #"identifier "com.apple.calculator" and anchor apple"#` → returns the URL (proves the check runs and passes on a match).
  - `appVerdictIsCached`: counting `locateApp` + the same URL twice → the second call does not re-run validation. Expose an internal `validationCount` for tests.
  - `appLocatorNilIsNil`.
  - `requirementsCompile`: both defaults → `errSecSuccess`.
  - `workingDirectoryOfSelf`: `readWorkingDirectory(getpid())` resolves to the same `URL.resolvingSymlinksInPath()` as `FileManager.default.currentDirectoryPath`; `nonexistentPIDHasNoWorkingDirectory` → `nil`.
- [ ] **Step 2: Run** `-only-testing:"Quick Access for Pass Tests/HerdrCodeSignatureVerifierTests"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(terminal-hosts): verify Herdr Core and Herdr.app signatures`

### Task 5: Core socket client and lookup provider

**Files:**
- Create: `Quick Access for Pass/Services/TerminalHosts/HerdrCoreSocketClient.swift`
- Create: `Quick Access for Pass/Services/TerminalHosts/HerdrCoreTerminalDetailsProvider.swift`
- Test: `Quick Access for Pass Tests/HerdrCoreTerminalDetailsProviderTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4, `HerdrSocketIdentity`, `CLIExecutionDeadline`.
- Produces:
  ```swift
  /// Connects, verifies the peer audit token as Core, sends one terminal.get line, reads one line ≤512 KiB.
  nonisolated protocol HerdrCoreSocketQuerying: Sendable {
      func terminalGet(socketPath: String, terminalID: String, deadline: CLIExecutionDeadline) async throws -> Data
  }
  nonisolated struct LiveHerdrCoreSocketClient: HerdrCoreSocketQuerying {
      init(verifier: any HerdrCodeSignatureVerifying, now: @escaping @Sendable () -> UInt64)
  }

  nonisolated struct HerdrCoreLookup: Equatable, Sendable {
      let herdrAppURL: URL?
      let details: HerdrCoreTerminalDetails?
  }
  nonisolated protocol HerdrCoreTerminalDetailsProviding: Sendable {
      /// nil = holder not verified (keep today's presentation). Non-nil = recognized; details may still be nil.
      func lookup(_ match: HerdrCoreTerminalMatch) async -> HerdrCoreLookup?
  }
  nonisolated struct LiveHerdrCoreTerminalDetailsProvider: HerdrCoreTerminalDetailsProviding {
      init(query: any HerdrCoreSocketQuerying, verifier: any HerdrCodeSignatureVerifying,
           readProcess: @escaping @Sendable (pid_t) -> RequesterProcessSnapshot.ProcessNode? = { RequesterProcessCapture.readNode($0) },
           readSocket: @escaping @Sendable (String) -> HerdrSocketIdentity? = { HerdrSocketIdentity.read($0) },
           readWorkingDirectory: @escaping @Sendable (pid_t) -> String? = { RequesterProcessCapture.readWorkingDirectory($0) },
           homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
           now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds })
  }
  ```

Socket client:
- The blocking socket work runs on a dedicated thread/queue, bridged with `CheckedContinuation` as in `CLIRunner`/`RunProxy`. **Only the worker ever closes the fd.** Cancellation (`withTaskCancellationHandler.onCancel`) only signals: it sets a lock-protected `cancelled` flag and calls `shutdown(fd, SHUT_RDWR)` while the fd is known open under that lock. The worker checks the flag after every `poll`.
- It uses a non-blocking `AF_UNIX` connect and `poll` bounded by the remaining deadline. `getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)` → `verifier.isVerifiedCore(auditToken:)`; if that fails, it closes the socket and throws **before writing**.
- The request line is the fixed template with `terminalID` spliced in from `JSONEncoder` (`outputFormatting = .withoutEscapingSlashes`) encoding of the String: `{"jsonrpc":"2.0","id":1,"method":"terminal.get","params":{"terminal":<encoded>}}\n`. Writes loop over partial writes/`EAGAIN` after `poll(POLLOUT)`; reads loop after `poll(POLLIN)`, each poll bounded by the remaining deadline. Reading stops at `\n`; more than 512 KiB without one throws. The worker always closes.

`lookup` (`@concurrent`), with `deadline = now() + 750_000_000` and `checkBudget` (cancellation + deadline) after every step:
1. `revalidate(match)`; `verifier.isVerifiedCore(pid: holder.pid)`; `revalidate(match)` again. Failure → return `nil`.
2. Start the app check as an **unstructured** `Task.detached` (its verdict still fills the verifier cache), run the details path below, then race the app task's value against the remaining deadline. Use an injected `sleep: @Sendable (UInt64 nanoseconds) async throws -> Void` (default `Task.sleep`) and a task group whose first result wins. If the deadline wins, `herdrAppURL = nil`, and the detached task is left to finish into the cache.
3. Details path:
   - Validate the socket path; `before = readSocket(path)`, owner `getuid()`.
   - `data = try await query.terminalGet(...)`; `terminal = try decoder.terminal(fromResponse:)`.
   - Require `address == hint.terminalID`, `state == "live"`, `pid == terminalRoot.pid`.
   - Read `folder = readWorkingDirectory((programNode ?? requesterSideNodes[0]).pid)` **before** the final checks.
   - Require `readSocket(path) == before` and `revalidate(match)`.
   - Return `decoder.details(program: programNode.map { ($0.executablePath as NSString).lastPathComponent }, …)`. Any throw → `details = nil`.
4. Return `HerdrCoreLookup(herdrAppURL: appURL, details: details)`.

`revalidate`: every node in `requesterSideNodes + [holder]` re-reads equal (pid, parent, start time, path); PIDs unique and > 1; parent links contiguous ending at the holder.

- [ ] **Step 1: Write failing tests.** Use the fake verifier, a fake `HerdrCoreSocketQuerying` (records calls, with an optional gate and a `started()` handshake) and the synthetic clock pattern from `HerdrPaneDetailsProviderTests`:
  - `happyPath`: lookup → `HerdrCoreLookup(herdrAppURL: /Applications/Herdr.app, details: .init(programName: "claude", terminalLabel: "Herdr core documentation", workingDirectory: "~/Code/p"))`; query called once with `terminalID == "t5"`; a non-default socket `…/herdr-core/work/work.sock` also works.
  - `unverifiedHolderIsNil`: verifier pid check false → `nil`; query never called.
  - `appMissingOrUnverifiedStillRecognized` (**Review Focus 5**): app URL nil → `herdrAppURL == nil`, details present.
  - `slowAppCheckDoesNotBlockDetails` (**Review Focus 5**): the fake app check blocks on a gate that is never opened before `lookup` returns; the injected sleeper returns immediately (deadline reached) → details present, `herdrAppURL == nil`. Open the gate afterwards to let the detached task end.
  - `ownershipFailures` (arguments): pid ≠ root; address ≠ hint; state `"finished"`; a chain node's start time changes during the query; socket identity changes during the query (**Review Focus 3**); socket owner ≠ uid; relative or overlong socket path → recognized lookup with `details == nil`.
  - `queryErrorsFallBack` (arguments): the query throws a peer-not-Core error (**Review Focus 1**), connection reset, or oversize → `details == nil`.
  - `lateReplyFallsBack`: the fake advances the synthetic clock by 750_000_001 ns, then returns valid JSON → `details == nil`.
  - `cancellationReturnsWithoutDetails`: the gated query hits `started()`, then the caller cancels → `details == nil` and the fake observed cancellation.
  - `socketClientCancellationDoesNotLeakFd` (live client): the listener accepts but never replies; cancel the caller → it throws `CancellationError` promptly, and the listener sees EOF (the worker shut down and closed exactly once).
  - `socketClientRejectsNonCorePeer` (**Review Focus 1**, live client): a test `AF_UNIX` listener in a temp directory, with a verifier whose `isVerifiedCore(auditToken:)` returns false → throws, and the listener receives 0 bytes. With true → the listener receives exactly the request line for `"t5"`. With a 600 KiB reply and no newline → throws.
- [ ] **Step 2: Run** `-only-testing:"Quick Access for Pass Tests/HerdrCoreTerminalDetailsProviderTests"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `HerdrPaneDetailsProviderTests` → PASS.
- [ ] **Step 5: Commit** `feat(terminal-hosts): look up Herdr Core terminals over the verified socket`

### Task 6: Presentation, rows and view

**Files:**
- Modify: `Quick Access for Pass/Models/RequesterPresentation.swift`
- Modify: `Quick Access for Pass/Models/RequesterHeaderContext.swift`
- Modify: `Quick Access for Pass/Views/Shared/RequesterHeaderView.swift`
- Modify: `Quick Access for Pass/Resources/Localizable.xcstrings`
- Test: `Quick Access for Pass Tests/RequesterHeaderContextTests.swift`

**Interfaces:**
- Consumes: Task 3.
- Produces:
  ```swift
  nonisolated enum RequesterIcon: Equatable, Sendable { case bundle(URL), symbol(String) }
  // RequesterPresentation gains defaulted vars (existing inits compile):
  var iconOverride: RequesterIcon? = nil
  var coreDetails: HerdrCoreTerminalDetails? = nil
  // RequesterHeaderContext.Kind:
  case programAndTerminal
  // RequesterHeaderContext.Row gains:
  var accessibilityValue: String? = nil   // nil → value
  ```
Rows for `coreDetails` (classic rows unchanged; never both):
- `programAndTerminal`: value `[program, label].joined(" · ")`, accessibility value joined with `", "`. The label is dropped if `normalized(label) == normalized(displayedCommand)`. No row if both are missing.
- `workingDirectory` (existing kind).

View:
- The `.bundle(url)` override uses the model-provided `NSImage` (Task 7) rather than calling `NSWorkspace` in `body`.
- `.symbol(name)` renders `Image(systemName: name).resizable().scaledToFit().frame(width: 48, height: 48).foregroundStyle(.secondary)`.
- The new kind gets symbol `"terminal"` and accessibility label `"Program and terminal"`. Rows use `row.accessibilityValue ?? row.value`.

Localization: `"Program and terminal"` → Czech `"Program a terminál"`; context: "Accessibility label for a requester header row showing the requesting program and terminal name".

- [ ] **Step 1: Write failing tests:**
  - `coreRowsProgramLabelAndFolder` → `[.init(kind: .programAndTerminal, value: "claude · review", accessibilityValue: "claude, review"), .init(kind: .workingDirectory, value: "~/p")]`.
  - `coreLabelEqualToCommandIsDropped` (`"git  fetch"` vs `"git fetch"`) → value `"claude"`.
  - `coreProgramOnlyAndLabelOnly`; `coreEmptyHasNoRows`.
- [ ] **Step 2: Run** `-only-testing:"Quick Access for Pass Tests/RequesterHeaderContextTests"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(prompts): show Herdr Core program, terminal and folder rows`

### Task 7: Header model integration and wiring

**Files:**
- Modify: `Quick Access for Pass/ViewModels/RequesterHeaderModel.swift`
- Modify: `Quick Access for Pass/App.swift` (one shared verifier, socket client and `herdrCoreTerminalDetailsProvider`)
- Modify: `Quick Access for Pass/AppDelegate+Coordinators.swift` (pass the provider at both coordinator sites)
- Modify: `Quick Access for Pass/Services/SSHAgent/SSHProxyCoordinator.swift`, `Quick Access for Pass/Services/RunProxy/RunProxyCoordinator.swift`
- Modify: test call sites that build `RequesterHeaderModel` or the coordinators (e.g. `RunAuthWindowControllerTests.swift`)
- Test: `Quick Access for Pass Tests/RequesterHeaderModelTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 5, 6.
- Produces: `RequesterHeaderModel.init(clientInfo:snapshot:store:detailsProvider:coreDetailsProvider: any HerdrCoreTerminalDetailsProviding)`. The parameter is **required**, with no live default. Coordinators get a required `coreDetailsProvider:` too, injected only from `App.swift`. Model gains `private(set) var overrideIconImage: NSImage?`.

Behavior:
- init: `coreMatch = HerdrCoreTerminalResolver.match(...)` (pure). If non-nil, `detailsEligible = true`.
- Add a private `presentation(with details:…)`-style copy helper. **Every** presentation rebuild, including `cancel()` and the classic publish, carries `iconOverride`/`coreDetails` through, so `cancel()` clears `coreDetails` but keeps the icon.
- In init, compute classic eligibility first, then `if coreMatch != nil { detailsEligible = true }`, so Core wins. Core ignores classic `hostMatch`.
- `loadDetails()`, Core branch: placed **before** the classic `let hostMatch` guard. Run one attempt as `@ObservationIgnored coreOperation: Task<HerdrCoreLookup?, Never>`, wrapped in `withTaskCancellationHandler` like the classic path. After the await, check `!cancelled && generation == currentGeneration && !Task.isCancelled`. On non-nil:
  - Set `iconOverride = appURL.map(.bundle) ?? .symbol("terminal")`.
  - For `.bundle`, set `overrideIconImage = NSWorkspace.shared.icon(forFile:)` once, here, on the main actor.
  - Set `coreDetails = lookup.details`.
- `refreshConfiguration()`: return immediately when `coreMatch != nil`. Core is not store-configurable, and this exemption gets documented in Task 8.
- `cancel()`: cancels `coreOperation` and clears `coreDetails`.

- [ ] **Step 1: Write failing tests** with a gated fake Core provider (call count, `started()`, `cancellationObserved`). The client is `name: "Herdr Core", bundleIdentifier: "dev.herdr.core", bundleURL: <bundle>` with a Core snapshot:
  - `coreLookupPublishesOnce`: before → name `"Herdr Core"`, no override. After → `.bundle(appURL)`, `overrideIconImage != nil`, `coreDetails` set. A second `loadDetails()` adds no calls.
  - `coreWithoutHerdrAppUsesTerminalSymbol` → `.symbol("terminal")`, `overrideIconImage == nil`.
  - `unrecognizedCoreKeepsPresentation`: lookup `nil` → presentation unchanged.
  - `coreCancellationIsTerminal` (arguments: view-task cancel, `model.cancel()`): a late finish publishes nothing, and the provider observed cancellation.
  - `storeChangesDoNotAffectCore`: `store.update(...)` while the lookup is gated, then finish → still publishes; name still `"Herdr Core"`.
  - `nonCoreClientNeverCallsCoreProvider`: existing Herdr fixture → core calls 0.
  - `coreWinsOverClassicMapping`: a Core requester whose chain also matches an enabled classic Herdr entry → Core provider called once, classic provider called 0 times.
  - `cancelKeepsOverrideIcon`: after publication, `cancel()` → `coreDetails == nil`, `iconOverride` unchanged.
  - `coreRowsGrowDialogs`: `dialogSizes` before/after → both SSH and Run heights grow.
- [ ] **Step 2: Run** `-only-testing:"Quick Access for Pass Tests/RequesterHeaderModelTests"` → FAIL.
- [ ] **Step 3: Implement** model branch, view use of `overrideIconImage`, wiring, and update existing call sites with a fake/no-op Core provider.
- [ ] **Step 4: Run** `RequesterHeaderModelTests`, `RunAuthWindowControllerTests`, and any SSH auth window tests → PASS; the Debug build succeeds.
- [ ] **Step 5: Commit** `feat(prompts): enrich Herdr Core requesters in SSH and Run prompts`

### Task 8: Docs, localization gate, full verification

**Files:**
- Modify: `docs/terminal-hosts.md` ("Herdr Core" section covering: automatic; rows; icon rule; any session via the verified socket; limits; separate from classic Herdr and the app)
- Modify: `SECURITY.md` terminal-host boundary:
  - the `HC_TERMINAL_ID`/`HC_TERMINAL_SOCKET` hints;
  - holder and socket-peer signature checks;
  - the single read-only `terminal.get` request;
  - the ownership proof;
  - Herdr.app is used for its icon only;
  - no binary is executed.
- Modify: `AGENTS.md` / `CLAUDE.md` "Shared requester presentation": add a Core sentence and the store-change exemption. Edit once if one file is a symlink to the other.
- Modify: `docs/superpowers/specs/2026-11-12-herdr-core-requester-context-design.md`. Record the plan-review changes:
  - socket JSON-RPC instead of the CLI;
  - all sessions supported;
  - the icon is published with the single lookup result;
  - folder falls back to the requester when there is no program.

- [ ] **Step 1:** Write the doc changes.
- [ ] **Step 2: Run** all tests → PASS; localization script → PASS.
- [ ] **Step 3: Manual check** in a Herdr Core pane after `make install`: `ssh -T git@github.com` and a `qa-run` command show the program row, folder and Herdr.app icon. If not possible, say so.
- [ ] **Step 4: Commit** `docs: describe Herdr Core requester context`
