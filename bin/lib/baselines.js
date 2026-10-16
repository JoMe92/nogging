'use strict';

// Pre-computed historical release baselines for SHA-256 tracking of verbatim files.
// Used for backward-compatible upgrades of installations created prior to
// manifest tracking (Decision 3).

const BASELINES = {
  '2.1.0': {
  ".agents/skills/.openspec-target": "243b0dc9b847e66c440dca985e10fe0ce9e29c379b018ddd5747ba8948f84cc8",
  ".agents/skills/beads/SKILL.md": "1a621606cfa9a14cbacff84bf5c496b4c2c175c2df329e8d19d4e01fc989dedd",
  ".agents/skills/beads/agents/openai.yaml": "c7ff618a9a6bcce71b25f722f67861b7685651d08fb72d8fff7d947aac403718",
  ".agents/skills/openspec-apply-change/SKILL.md": "7c79315715da88639e60f05268206ba72939ef9bf298c6f3195152d09d20b3fe",
  ".agents/skills/openspec-archive-change/SKILL.md": "e0ffaacdb982e7440e97979422a91178cc93220a5805bd07cbdaef82c33284ac",
  ".agents/skills/openspec-explore/SKILL.md": "95ed31936b538cbf44b5e3f7f81da50defd256d96048ee370d82b36e8ff5c486",
  ".agents/skills/openspec-propose/SKILL.md": "0c95777dd8cc28f52dc4d6e2a51beeb1917a6638bed51baa710735721784d731",
  ".agents/skills/openspec-sync-specs/SKILL.md": "da0ae40869be60ceff6cd231c75976487875675a7eca390b61a932b081aa91d4",
  ".agents/skills/openspec-update-change/SKILL.md": "23bd9d7d95cc34caee693f7f3671ec8d49f8eca436483d3e29bea43e511b87d5",
  ".claude/agents/architect.md": "504f8f1cc310c8c9ef635fcb390c58f4c525c59cf470dc7851ca981f7ef93454",
  ".claude/agents/backend-engineer.md": "bfd369e06073f83a88594bb0b2fd8b52a3005d12566024a8e25cc769ab13b988",
  ".claude/agents/code-reviewer.md": "26df935887b9cc9a9ba790c18ad096d2786084e504db468a3551d68095b60f26",
  ".claude/agents/frontend-engineer.md": "940422e10bfbe5d77d66b97e222164eae1b77ff8d23c65599a6e834797658b88",
  ".claude/agents/test-runner.md": "a1420a4befb5f1c5ee927ed7dacbc90e171ceb0084bd3ca98f517b98045276be",
  ".claude/agents/ui-ux-designer.md": "4e7f4789a76378adfccc781ede7aa235c7a4297a03eb84b492350d4424338dd3",
  ".claude/commands/discovery-review.md": "e5c492778cb4eac5d37cbc16d15230ca516b87233d09792823c62069b497fb62",
  ".claude/commands/orchestrate.md": "905a46fc480f3a06e849c54950a5f134c525c7cac45501540e09e2fe93ea616a",
  ".claude/commands/plan.md": "f29257fffe3be972dbce540f64cf19d40da1d29f39862ec11138c9cc653680d6",
  ".claude/commands/sync-now.md": "c4fc2f578153af2894a40254fccc87c8b781ea32731b1429aec09bb53c33d8d0",
  ".codex/prompts/discovery-review.md": "f41af16432dd71ad8978b8cb962c32a4d3ec99d4e989bb43cc9d247c6f020374",
  ".codex/prompts/plan.md": "9634088324f0b06bfa89bad05ea5fa56b58dcc15208f3fa786669c9e33be5ec2",
  ".codex/prompts/sync-now.md": "c4fc2f578153af2894a40254fccc87c8b781ea32731b1429aec09bb53c33d8d0",
  ".codex/rules/nogging.rules": "44dbbddd47431b702aba1d3a8d3a529af6b11c5fe391cc57f63c58440ec548b5",
  ".nogging/launch-profiles/orchestrator.json": "0cf25a010a64148018201d3a752e7979298a285f56be10c7b2da7cfd3055d3d5",
  ".nogging/launch-profiles/restricted.codex.toml": "9f5647e9f93bb7c6ac0ea035ae52a001578dc3020880b4fd43ef05dca89ce66f",
  ".nogging/launch-profiles/restricted.json": "28dac3da0a8c160245f6f64387ad4619f98cc34745667af198fbd174fc10f714",
  ".nogging/launch-profiles/restricted.pi.toml": "80ad978c5cfd6935bba61cda06325a605a71e3f9f8a40ed6244a81640df8f287",
  ".nogging/launch-profiles/trusted.codex.toml": "7482a2388aacfb5f793f40f2356868f2ca453fd82f530ae9febd3dbbbb166798",
  ".nogging/launch-profiles/trusted.json": "ab36f91368e13517576cdae419493793b35641626acbdb98f0ee5ab61a9eaba5",
  ".nogging/launch-profiles/trusted.pi.toml": "8e8cbf48b658deeadcf6ba0212bde769435562363d09ad906b341acdbe2aa437",
  ".nogging/launch-prompts/autonomous.md": "311e3ba055a71f55e5022a464fe702efd1236d6aed7e49fb3dbde2ad056efced",
  ".nogging/launch-prompts/no-autonomous-claim.md": "7a29564452002cde0e6e3e37b4605cb09a15810b7a4bb6ecf032e42459ca3cfe",
  ".nogging/launch-prompts/orchestrator.md": "b326c456df71f426b4ce586f82733f4191130a1ef7343bfb896527cf83da5337",
  ".pi/extensions/nogging-guard.ts": "0aa61ca50f6b77f00769af887f5611244e2c1a6a8ef887f0423e124cae878423",
  ".pi/prompts/discovery-review.md": "f41af16432dd71ad8978b8cb962c32a4d3ec99d4e989bb43cc9d247c6f020374",
  ".pi/prompts/plan.md": "84057acf963e9fa161e9d3343404346c6e3e8a8f239ebfbd88520412b29f405c",
  ".pi/prompts/sync-now.md": "c4fc2f578153af2894a40254fccc87c8b781ea32731b1429aec09bb53c33d8d0",
  "docs/nogging/architecture.md": "949825ed72d1098b16ac9a618e0fc6eccde78a09237610a45c076661cc8c7e15",
  "docs/nogging/compatibility.md": "c55016ef07b8f8a6695305a5494f2e73934368185529617958f5b1ccc21dd598",
  "docs/nogging/failure-recovery.md": "f927d11de0a2950ec8bb40ec2995b2a8d900dde71c28f5c1a6aafb6a756c9569",
  "docs/nogging/operating-model.md": "92bdae39f7f0eb6a5bd0921cad4e37a7fb6cfcb05275cb103457e8dd03571199",
  "docs/nogging/security-model.md": "945f88d149814473396f10c24f8ad3c00891f3dc4e2abe640ee8930ba3009feb",
  "docs/nogging/using-with-codex.md": "b5eab3737f2e626c5eecd0ecce42d953274080a158f6cfbb99c40b29f5d68ea0",
  "docs/nogging/using-with-pi.md": "f33b718ee642a0832134c60f32204e7bf237bbbd61fcc37a0386e0b8b601516b",
  "docs/nogging/worktree-workflow.md": "84c0ec72d5845c4966aa2130dd362d4fce2e3511c0d7a73a387233da1b6d86d9",
  "scripts/check-branch-name": "72b293068402254f863a258b1344f9a6d0580ca44178d5c1ee72c626ed786237",
  "scripts/hooks/branch-name.test.sh": "54dad9de94e88dfd4bac4c3d0232bd4b666cfa860f0a3ffea110b20e15e32a2b",
  "scripts/hooks/commit-msg": "241949cef6c0cd0073153b4871c3ee0eb9d7ef1ef56faa5d58343e36cbf9f81c",
  "scripts/hooks/commit-msg.test.sh": "2095dc8b97a19a4bdff749bd85d4f800ab4c8f1225ef494fe5bf57d162dded22",
  "scripts/hooks/pre-commit": "0a1625b240ddc158e2c751035343ac9280fca5aec1a65aca4a501c65049d160c",
  "scripts/hooks/pre-push": "83a78f679a3ec64f78f62f076b26622ad8a3c5d2896a429ac21505719c114a4c",
  "scripts/hooks/pre-tool-use-openspec-guard": "ff5e4a60ffccf973dabe3346a6dbdc97e723141c9939bdf437b01a35c6f0b30c",
  "scripts/hooks/session-start-cloud-bootstrap": "d876e0a8905b3e53989090718f1f211caa901c134a8740d2ee485444f30f870c",
  "scripts/hooks/session-start-cloud-bootstrap.test.sh": "618d818c5df3c12c0ae35be5ddc72b5251757d11de3f7d4e69bb2eca4a4ff297",
  "scripts/install-hooks": "e7ec09616df50a4fc1dafde4654e6c43c081bf4640500f9aa62089a531e66171",
  "scripts/nogg": "2c32a2309ab6881a2bdc20b5c471213d4a1a6e217196a75268180979139a7b0b",
  "scripts/nogg.test.sh": "88e93186047653b395b316e57ec09e2c1ac8e44a4ed0580ba39e42f295a31192",
  "scripts/test": "7db14715522d692cf24b9ada05659742d2e00e2150b7c236584677ec56194889",
  "scripts/worktree-workflow.test.sh": "a08ee1d3037e1544289e331a602bb66107cffe4474f862e91794c5b940477156"
},
  '2.2.0': {
  ".agents/skills/.openspec-target": "243b0dc9b847e66c440dca985e10fe0ce9e29c379b018ddd5747ba8948f84cc8",
  ".agents/skills/beads/SKILL.md": "1a621606cfa9a14cbacff84bf5c496b4c2c175c2df329e8d19d4e01fc989dedd",
  ".agents/skills/beads/agents/openai.yaml": "c7ff618a9a6bcce71b25f722f67861b7685651d08fb72d8fff7d947aac403718",
  ".agents/skills/nogging-discovery-review/SKILL.md": "3d9b2b4c31843548947dee52d637907bc463b612a33edce271229352351cddcd",
  ".agents/skills/nogging-plan/SKILL.md": "f5521d81a8b1f97fd67e834aa249fbae2ff2c3c206bf8c8dfcc5fbd28685d228",
  ".agents/skills/nogging-sync-now/SKILL.md": "f1c1e541dd29e748b7b0394f83a48fbab440387bd2e6cf587d29569b01102903",
  ".agents/skills/openspec-apply-change/SKILL.md": "7c79315715da88639e60f05268206ba72939ef9bf298c6f3195152d09d20b3fe",
  ".agents/skills/openspec-archive-change/SKILL.md": "e0ffaacdb982e7440e97979422a91178cc93220a5805bd07cbdaef82c33284ac",
  ".agents/skills/openspec-explore/SKILL.md": "95ed31936b538cbf44b5e3f7f81da50defd256d96048ee370d82b36e8ff5c486",
  ".agents/skills/openspec-propose/SKILL.md": "0c95777dd8cc28f52dc4d6e2a51beeb1917a6638bed51baa710735721784d731",
  ".agents/skills/openspec-sync-specs/SKILL.md": "da0ae40869be60ceff6cd231c75976487875675a7eca390b61a932b081aa91d4",
  ".agents/skills/openspec-update-change/SKILL.md": "23bd9d7d95cc34caee693f7f3671ec8d49f8eca436483d3e29bea43e511b87d5",
  ".claude/agents/architect.md": "504f8f1cc310c8c9ef635fcb390c58f4c525c59cf470dc7851ca981f7ef93454",
  ".claude/agents/backend-engineer.md": "bfd369e06073f83a88594bb0b2fd8b52a3005d12566024a8e25cc769ab13b988",
  ".claude/agents/code-reviewer.md": "26df935887b9cc9a9ba790c18ad096d2786084e504db468a3551d68095b60f26",
  ".claude/agents/frontend-engineer.md": "940422e10bfbe5d77d66b97e222164eae1b77ff8d23c65599a6e834797658b88",
  ".claude/agents/test-runner.md": "a1420a4befb5f1c5ee927ed7dacbc90e171ceb0084bd3ca98f517b98045276be",
  ".claude/agents/ui-ux-designer.md": "4e7f4789a76378adfccc781ede7aa235c7a4297a03eb84b492350d4424338dd3",
  ".claude/commands/discovery-review.md": "e5c492778cb4eac5d37cbc16d15230ca516b87233d09792823c62069b497fb62",
  ".claude/commands/orchestrate.md": "18cbbb25b2f9ba1876aa29981394f51382bd1cde687f464865273b9fb19268de",
  ".claude/commands/plan.md": "3332989954bb40fabd95e59325b5c3b0e067d30cfa781f8e08c6dd8d337e40a7",
  ".claude/commands/sync-now.md": "c4fc2f578153af2894a40254fccc87c8b781ea32731b1429aec09bb53c33d8d0",
  ".codex/prompts/discovery-review.md": "f41af16432dd71ad8978b8cb962c32a4d3ec99d4e989bb43cc9d247c6f020374",
  ".codex/prompts/plan.md": "9f49bf3363b87ed1ef7f34d13f2dbf3e761bb45d8f5eb20f8b7dd4bca4c02f50",
  ".codex/prompts/sync-now.md": "c4fc2f578153af2894a40254fccc87c8b781ea32731b1429aec09bb53c33d8d0",
  ".codex/rules/nogging.rules": "44dbbddd47431b702aba1d3a8d3a529af6b11c5fe391cc57f63c58440ec548b5",
  ".nogging/launch-profiles/orchestrator.json": "0cf25a010a64148018201d3a752e7979298a285f56be10c7b2da7cfd3055d3d5",
  ".nogging/launch-profiles/restricted.agy.toml": "132e347c0a1fa27e77255f67854fa32e8e29983294e9b2cb4fff097af0ec67f0",
  ".nogging/launch-profiles/restricted.codex.toml": "d48adc218ff0434a8f71a4ba4f8251e81ce2dd6f8ab654e87f0d871c3339ae7e",
  ".nogging/launch-profiles/restricted.json": "28dac3da0a8c160245f6f64387ad4619f98cc34745667af198fbd174fc10f714",
  ".nogging/launch-profiles/restricted.pi.toml": "80ad978c5cfd6935bba61cda06325a605a71e3f9f8a40ed6244a81640df8f287",
  ".nogging/launch-profiles/trusted.agy.toml": "25ea0f68758bf9446900ffed0b5562497fca0ca23489100bb31d32c08be404b4",
  ".nogging/launch-profiles/trusted.codex.toml": "5dea46d692c6e20d604adec8286bc86dc42e90c4b0f46581059d916c8877ac57",
  ".nogging/launch-profiles/trusted.json": "d234e9e38600b8e3b0568451716e424b5e6f562e2630f85ddfbb0b677040f3c3",
  ".nogging/launch-profiles/trusted.pi.toml": "8e8cbf48b658deeadcf6ba0212bde769435562363d09ad906b341acdbe2aa437",
  ".nogging/launch-prompts/autonomous.md": "331ba9fac1cd7fe01d6474feeaf9568f3c1fdc6267766b5e800f4f08c1517bf0",
  ".nogging/launch-prompts/no-autonomous-claim.md": "330ceec63f98f83d9d2bcd8e9b3d253a38eca88b3b050130ce45da7d79446a70",
  ".nogging/launch-prompts/orchestrator.md": "c6977974ffa21ed02536b2dd5889036da9c1f8f94bb3a4f2f593739934594f00",
  ".nogging/launch-prompts/planning.md": "6ba936e4d343e15e9756208af9b0d0087b7a275397fa403863201eaf78a7c174",
  ".pi/extensions/nogging-guard.ts": "f814ce0989f407bed5134f8b200eec514ce2347948e65cef6f7c1c56aaad1e56",
  ".pi/prompts/discovery-review.md": "f41af16432dd71ad8978b8cb962c32a4d3ec99d4e989bb43cc9d247c6f020374",
  ".pi/prompts/plan.md": "dd77d8b92c179c25f1dbfc7785dc8299397cbd660ff5ec44e2436710bc821547",
  ".pi/prompts/sync-now.md": "c4fc2f578153af2894a40254fccc87c8b781ea32731b1429aec09bb53c33d8d0",
  "docs/nogging/architecture.md": "6f4c566562192ff4ebddc69933083a1f21390e9f5893d28ed9609dcd2ad06429",
  "docs/nogging/compatibility.md": "5926958db14754d78c6ada3e9f2241a7039cdf3d69a363afad0bc98b974d7cd1",
  "docs/nogging/failure-recovery.md": "37d636002c1389b05738fbd94a962b41cc70d83fd3ccd1bd6c06ec0a78480995",
  "docs/nogging/model-selection.md": "dc62710076f5aec389afe8c7c7236f2bc0dfbad1a385be8e554040129afb40e9",
  "docs/nogging/operating-model.md": "46755d8be715944ff561b58aad505e1f607f8bbbf6eeaa3b875ce9d8453c5291",
  "docs/nogging/security-model.md": "4dab129f62871522635dd4e0175d6ece83a79611d67255a0e8528b5afc8f25ba",
  "docs/nogging/token-usage.md": "768d3d0a2ad5bbdf5c754d40d3c69150f75eec9153a147491ad5f15cfac8d702",
  "docs/nogging/using-with-antigravity.md": "00705b60eef1cb2eac63f4903654c4534eb776d6f96571787ed50850e5c10b59",
  "docs/nogging/using-with-codex.md": "e3d04f2887fd0ace44454663d5ae990a04d5a6010c169a5025f0bea5087b1262",
  "docs/nogging/using-with-pi.md": "89c2f2bc38bfc05572777b9fd52f8ecc9d3e133f07bf2687c46d5fde90595d88",
  "docs/nogging/worktree-workflow.md": "70f171d3dfd315b2a5147e2b09e18ab49b73b0fcadabada0c38fa9042943410b",
  "scripts/check-branch-name": "72b293068402254f863a258b1344f9a6d0580ca44178d5c1ee72c626ed786237",
  "scripts/hooks/agy-guard": "97de39517d9730400947938866452df3d17c78c15d8da6956c072cfa12f6aa45",
  "scripts/hooks/branch-name.test.sh": "54dad9de94e88dfd4bac4c3d0232bd4b666cfa860f0a3ffea110b20e15e32a2b",
  "scripts/hooks/commit-msg": "241949cef6c0cd0073153b4871c3ee0eb9d7ef1ef56faa5d58343e36cbf9f81c",
  "scripts/hooks/commit-msg.test.sh": "2095dc8b97a19a4bdff749bd85d4f800ab4c8f1225ef494fe5bf57d162dded22",
  "scripts/hooks/pre-commit": "0a1625b240ddc158e2c751035343ac9280fca5aec1a65aca4a501c65049d160c",
  "scripts/hooks/pre-push": "83a78f679a3ec64f78f62f076b26622ad8a3c5d2896a429ac21505719c114a4c",
  "scripts/hooks/pre-tool-use-lead-launch-guard": "8e8fc47f85d8283bd5509ee864d50b98d065a08906ec072793f1a7a3085beaa8",
  "scripts/hooks/pre-tool-use-lead-launch-guard.test.sh": "c5c38b147b497427889b185174b8b6965859fc3b3f67e788e6de4be87d38ec3f",
  "scripts/hooks/pre-tool-use-openspec-guard": "c011fb7bcfaaac92b309c91b936b63560d4dfe61b104b967ed134decfa270862",
  "scripts/hooks/session-start-cloud-bootstrap": "d876e0a8905b3e53989090718f1f211caa901c134a8740d2ee485444f30f870c",
  "scripts/hooks/session-start-cloud-bootstrap.test.sh": "618d818c5df3c12c0ae35be5ddc72b5251757d11de3f7d4e69bb2eca4a4ff297",
  "scripts/install-hooks": "e7ec09616df50a4fc1dafde4654e6c43c081bf4640500f9aa62089a531e66171",
  "scripts/lib/token_usage_adapters.py": "722b191cb99d5ff9535bb48a990c5d9fe0990dceea01db9aa5efc9424c7f8546",
  "scripts/lib/token_usage_antigravity.py": "4bc84b6d8db0c065790505f4e0d058333c8a7b09119c9ccc0b25408e2aca2f3c",
  "scripts/lib/token_usage_collect.py": "ad6498818f066e8d62f90bd60cac8fcd6d3d2fdf282cb650009934f90b528c21",
  "scripts/lib/token_usage_report.py": "e83aa873604fe1e3eae7fc27f89448ae224770678a56d766d982dcd46ea9e094",
  "scripts/lib/token_usage_store.py": "03664cc59a13e1fb1e1d25c90798187d7488482a16907bbd872c1af13df7fdbd",
  "scripts/lib/token_usage_sync.py": "6f9393f61491964b43a0ee6276062dfcf84e1faef20f6d2601b7edf5eb289a4a",
  "scripts/nogg": "05290982ea7930fb6bb66fd8d979d63c41e964152a00467c816aed986ab5552b",
  "scripts/nogg.test.sh": "1bb3eb3381455a42f9056cfc97c3d3f901355341ace9030289f2b563d0d723f5",
  "scripts/nogg_usage.py": "abab94b95bfa9f70545f3e6db202cec7c2aad6404fb376f2b3c863976395d69b",
  "scripts/openspec-sandbox": "9cce7cb291a9b7b5f0f4034c641589c7f78cbf89ce6f2ded1c01dc920a3b0764",
  "scripts/session-launch": "422224933244e9159bea0c40c36182291d5dfdbebd14523af29407b31483b243",
  "scripts/session-log-writer": "b322fefa31be7159b3fb1eabca238ddbf6cd1f49bf49b998f9d4fb26662f49cb",
  "scripts/test": "00f202d772239d26da18e57d84b11448499d51196878c802264d5c02f73a6fd0",
  "scripts/worktree-workflow.test.sh": "2bd39c169695942d9a0b866752b0a76c1db22631f2266d80e89ff1f8815087f2",
  "templates/claude/orchestrator-permissions.example.json": "9a774ac270723bb26863cb0303c134d504ce83092e702ab58fc3488c52585b0a"
},
};

function normalizeVersion(version) {
  if (version == null) return null;
  const s = String(version).trim();
  return s.startsWith('v') ? s.slice(1) : s;
}

function getBaseline(version) {
  const norm = normalizeVersion(version);
  return (norm && BASELINES[norm]) || null;
}

function lookupFileHash(relPath, version) {
  const baseline = getBaseline(version);
  return (baseline && baseline[relPath]) || null;
}

function findMatchingBaseline(relPath, fileHash) {
  if (!fileHash) return null;
  const lowerHash = fileHash.toLowerCase();
  for (const [version, files] of Object.entries(BASELINES)) {
    if (files[relPath] && files[relPath].toLowerCase() === lowerHash) {
      return { version, hash: files[relPath] };
    }
  }
  return null;
}

function resolveBaselineHash(relPath, recordedVersion, currentHash) {
  const normVer = normalizeVersion(recordedVersion);
  const baseline = normVer ? BASELINES[normVer] : null;
  const curLower = currentHash ? String(currentHash).toLowerCase() : null;

  // 1. If recorded version baseline exists and matches current hash:
  if (baseline && baseline[relPath] && curLower && baseline[relPath].toLowerCase() === curLower) {
    return baseline[relPath];
  }

  // 2. If current hash matches any bundled baseline for this file:
  if (curLower) {
    const match = findMatchingBaseline(relPath, curLower);
    if (match) return match.hash;
  }

  // 3. If recorded version is known and has an entry for this file, return that recorded baseline:
  if (baseline && baseline[relPath]) {
    return baseline[relPath];
  }

  return null;
}

module.exports = {
  BASELINES,
  normalizeVersion,
  getBaseline,
  lookupFileHash,
  findMatchingBaseline,
  resolveBaselineHash,
};
