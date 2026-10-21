# Changelog

## [0.2.0](https://github.com/www-zaq-ai/web_widget/compare/v0.1.0...v0.2.0) (2026-10-21)


### Features

* add container embedding, asset installer, and Markdown rendering ([ceb7155](https://github.com/www-zaq-ai/web_widget/commit/ceb7155ddfdb6018871da644db6c7003310e8ba9))
* add trusted deployment scope to host integration (ww-1xb) ([a30116d](https://github.com/www-zaq-ai/web_widget/commit/a30116d702f9b271e66f4b97f5bfbb4e432d955b))
* **assets:** make widget dependency self-contained ([9c0c5e9](https://github.com/www-zaq-ai/web_widget/commit/9c0c5e97b1bff186e23882d3805e82e2727cbe2d))
* **assets:** make widget dependency self-contained ([d20e025](https://github.com/www-zaq-ai/web_widget/commit/d20e02588dc057ef16d5e363909fe78c9fe19ca4))
* **auth:** add clustered Mnesia binding store (ww-v4a.2) ([f965c08](https://github.com/www-zaq-ai/web_widget/commit/f965c08734f5868deffd80effacb10042c30829a))
* **auth:** add signed backend disconnect control (ww-v4a.7) ([dc1e5c6](https://github.com/www-zaq-ai/web_widget/commit/dc1e5c60b0cc02d0902a3291f884281468572a1d))
* **auth:** bind JWT at connected LiveView mount (ww-v4a.3) ([47945b2](https://github.com/www-zaq-ai/web_widget/commit/47945b24523e27739e2d4ec0040aae4d675a2aec))
* **auth:** bootstrap and renew widget identity from parent (ww-v4a.5) ([ebf45e8](https://github.com/www-zaq-ai/web_widget/commit/ebf45e8f0acbc54dad32653202df931060a1acc8))
* **auth:** renew widget authorization in place (ww-v4a.4) ([fa5cd6a](https://github.com/www-zaq-ai/web_widget/commit/fa5cd6a2cddae1f7b6827562b830b4b67e6c2c0e))
* **auth:** separate conversation context from identity (ww-v4a.6) ([b93f624](https://github.com/www-zaq-ai/web_widget/commit/b93f6249e1fa63ff49f106a617a9c10f247bb1ea))
* **context:** create a post message to get context ([370a81c](https://github.com/www-zaq-ai/web_widget/commit/370a81cd0d7387f28b6b9892a3a089bb171541c0))
* **embed:** use shared installation script in demo and e2e tests ([4bd9775](https://github.com/www-zaq-ai/web_widget/commit/4bd97752865b259724b8dfa127383ba659610b23))
* explicit host startup ([0f6b0af](https://github.com/www-zaq-ai/web_widget/commit/0f6b0afa5584442806206fc1fddc0c23d34619ac))
* expose explicit widget infrastructure startup (ww-v12.1) ([0fe485e](https://github.com/www-zaq-ai/web_widget/commit/0fe485e06d491e738cf632e18cf431d9655a757a))
* expose host adapter and process-owned widget policies (ww-j0g) ([090f249](https://github.com/www-zaq-ai/web_widget/commit/090f2493914f5cae77c22cb5fb2963d170643440))
* expose scoped widget readiness ([#16](https://github.com/www-zaq-ai/web_widget/issues/16), ww-432) ([970fc2b](https://github.com/www-zaq-ai/web_widget/commit/970fc2bf00a6a90eb4d56de57b903b8572d12ba2))
* expose verified sender profiles to hosts (ww-qkv) ([cd8f212](https://github.com/www-zaq-ai/web_widget/commit/cd8f2124ebdc6f8368da57a81dc44919b955fb94))
* **integration:** add jwt-authenticated chat and history restoration ([e147a51](https://github.com/www-zaq-ai/web_widget/commit/e147a5101808021fca8e8c494fb4c4e573887d77))
* **integration:** add zaq runtime adapter and automatic iframe embedding ([2874770](https://github.com/www-zaq-ai/web_widget/commit/287477041079dbb8aefb9402e85358ee1ac42eeb))
* render canonical tool snapshots in live and restored conversations ([42b7ef7](https://github.com/www-zaq-ai/web_widget/commit/42b7ef71fd43bb62562c05e9f29581e8152a89cb))
* render canonical tool snapshots in live and restored conversations ([0473a7a](https://github.com/www-zaq-ai/web_widget/commit/0473a7ac30d79aa6729ddec49113223db31c5f01))
* render failed responses with safe Markdown ([a0feea2](https://github.com/www-zaq-ai/web_widget/commit/a0feea2ce0b22bfd02b7337275dad6e1071e3b77))
* **router:** add router macro ([c5126f3](https://github.com/www-zaq-ai/web_widget/commit/c5126f3f7f23dd2ba08b1b7447240dfeba2029df))
* separate v2 submission receipts from assistant streams (ww-gn1.1) ([d7ed897](https://github.com/www-zaq-ai/web_widget/commit/d7ed897fae3e519ae25ea5155d7c20b5e8f8805d))
* supervise connectors and verify trusted proxy deployments (ww-v12) ([6c6df55](https://github.com/www-zaq-ai/web_widget/commit/6c6df55e1835b97a83901a0acda06d35b00312f9))
* sync accepted user messages and acknowledge drafts (ww-4qm) ([193f23f](https://github.com/www-zaq-ai/web_widget/commit/193f23f3e05d4159b31796900c47ca929db79a33))
* verified sender profile ([ecdb65d](https://github.com/www-zaq-ai/web_widget/commit/ecdb65db21932cbcedbb9b45498f360e1b1f65fc))
* **web:** add streaming chat, conversation history, and themes ([07f8f47](https://github.com/www-zaq-ai/web_widget/commit/07f8f476483b645a2980af7ae49cdf066f958f76))
* **web:** initialize phoenix app with livereact and assistant-ui ([c7d91d2](https://github.com/www-zaq-ai/web_widget/commit/c7d91d26357eecc3c7b8225327f313d5b23de4fd))
* **web:** initialize phoenix app with livereact and assistant-ui ([8d9f66d](https://github.com/www-zaq-ai/web_widget/commit/8d9f66dbba1d3a530cfe7dd0b4033a5f60a47b14))
* **web:** replace config stylesheets with embed stylesheet-url attribute ([7e739c6](https://github.com/www-zaq-ai/web_widget/commit/7e739c62ea81646c1aa68334330f991b3fd30524))
* **widget:** add global embed api and simplify setup documentation ([7008487](https://github.com/www-zaq-ai/web_widget/commit/7008487234545888d40218d3b45b65c44f18804d))
* **widget:** add localization and runtime language and theme settings ([5bb9286](https://github.com/www-zaq-ai/web_widget/commit/5bb9286f440fd560ae549ec57731f4fffb0a70b7))
* **widget:** add powered by zaq.ai attribution link ([c4b241d](https://github.com/www-zaq-ai/web_widget/commit/c4b241d852d9b76e5cd320eee8855e5b4b8eb7a7))
* **widget:** control themes through css and expand browser coverage ([cf3189f](https://github.com/www-zaq-ai/web_widget/commit/cf3189fe3b0de03ccd129e57b05eb82f4bd891cf))
* **widget:** demo add-on requested ([ea0aade](https://github.com/www-zaq-ai/web_widget/commit/ea0aade5f204cd48ce739286d616768b70b877f4))
* **widget:** enforce origin allowlists and handle invalid widget urls ([c48cc84](https://github.com/www-zaq-ai/web_widget/commit/c48cc8462073b7661c36a9e3ddfc7a90b2924b32))
* **widget:** show reconnect status and validate recovery ([4ff3816](https://github.com/www-zaq-ai/web_widget/commit/4ff38168fad768d6e040fbb87d8c36a30b02871b))
* **widget:** version 0.1 ([1397b7a](https://github.com/www-zaq-ai/web_widget/commit/1397b7add20ba94009c9382958784f12f4231932))


### Bug Fixes

* accept omitted forwarded port for trusted HTTPS443 (ww-a9r) ([2559489](https://github.com/www-zaq-ai/web_widget/commit/2559489739a394f9ad57d8263ed4b2cab546f4a3))
* align readiness with session bootstrap ([#16](https://github.com/www-zaq-ai/web_widget/issues/16), ww-99x) ([07f2216](https://github.com/www-zaq-ai/web_widget/commit/07f2216f112ee65ecaaa9ba45e54e75a8c09dcfd))
* **authentication:** preserve bindings and reconnect recovery (ww-ocy) ([9c86b59](https://github.com/www-zaq-ai/web_widget/commit/9c86b592ec958e49c9d7ff86f0c354f527b0a52a))
* **authentication:** restore recovery ownership and readiness ([2830959](https://github.com/www-zaq-ai/web_widget/commit/2830959595935d038710486f1cd77e2fae79adf3))
* **authentication:** restore selected conversation on reconnect (ww-2mu) ([5ff8b5e](https://github.com/www-zaq-ai/web_widget/commit/5ff8b5ec4f8e801c47925aa985f9b01bae4486dc))
* **authentication:** security hardening ([df9b169](https://github.com/www-zaq-ai/web_widget/commit/df9b1698c486fd4d690d3a70c95c8f032cfdec2e))
* bind widget recovery to host recipient delivery (ww-4qm) ([0b949ca](https://github.com/www-zaq-ai/web_widget/commit/0b949ca66aa032ab0b002e056a98ec666bf157b1))
* clarify safe widget context update errors (ww-4qm) ([06f1d6d](https://github.com/www-zaq-ai/web_widget/commit/06f1d6d183704010f3f99017913103f2a7c9fd0c))
* deduplicate runtime and recovery indicators (ww-4qm) ([637c7bd](https://github.com/www-zaq-ai/web_widget/commit/637c7bd68649b582717b01e112b3d21cde44c4d7))
* **e2e:** remove the header assertion ([2b60950](https://github.com/www-zaq-ai/web_widget/commit/2b60950cfd4ae0094b812766eb1f975e92bc83f9))
* enforce connector-owned widget identity settings ([#10](https://github.com/www-zaq-ai/web_widget/issues/10), ww-6zy) ([cc192ff](https://github.com/www-zaq-ai/web_widget/commit/cc192ffe93fb3564e9213123233662e54c94ab0f))
* harden widget session initialization and recovery ([#12](https://github.com/www-zaq-ai/web_widget/issues/12), ww-o4z) ([9d47554](https://github.com/www-zaq-ai/web_widget/commit/9d47554152c6976027812b66d5af6fa0c730f2b3))
* isolate widget cookies and scoped LiveView transport ([#12](https://github.com/www-zaq-ai/web_widget/issues/12), ww-323) ([64a576a](https://github.com/www-zaq-ai/web_widget/commit/64a576aa3ab2e8ba789866a2137cb99ad034c915))
* let Phoenix recover widget connections ([dcb3f67](https://github.com/www-zaq-ai/web_widget/commit/dcb3f6742f937fc3982d11a76cf599c505eaae2c))
* migrate E2E fixtures to supervised connectors (ww-8wj) ([7a2ae84](https://github.com/www-zaq-ai/web_widget/commit/7a2ae8478e9097be00b41d078bd42b6aff42fdb1))
* open widget content links in a new tab (ww-2ji) ([5c75e4e](https://github.com/www-zaq-ai/web_widget/commit/5c75e4ed4bc8b04538b31be8b9ddca3d77d47f96))
* partition widget transport cookies by default ([#12](https://github.com/www-zaq-ai/web_widget/issues/12), ww-0r2) ([af9ef99](https://github.com/www-zaq-ai/web_widget/commit/af9ef993500211323a87b0c8df8cd6d275313734))
* report guarded HTTP feed as locally ready (ww-2ou) ([b666455](https://github.com/www-zaq-ai/web_widget/commit/b66645544a0b4d3d0cb4debfe8741bbe3ad3e466))
* show recovered processing in conversation (ww-4qm) ([1114f77](https://github.com/www-zaq-ai/web_widget/commit/1114f771ad5e3baf5c83fcbc6e544dc093d70616))
* stabilize partition E2E and unblock session reload (ww-9vq) ([4bd6929](https://github.com/www-zaq-ai/web_widget/commit/4bd6929bb599ced0bc4a9c0536588fb8b7a002b9))
* support host normalization before widget guards (ww-1pp) ([feea384](https://github.com/www-zaq-ai/web_widget/commit/feea384c16c5d3f9e6eac96e95b1c653efbe6e41))
* transport verified profiles through trusted context (ww-oqj) ([2d46d0d](https://github.com/www-zaq-ai/web_widget/commit/2d46d0d18bdfd21275d0e7b9e2a1c93d7de1f705))
* **widget:** display public error text for failed responses ([6c10f7e](https://github.com/www-zaq-ai/web_widget/commit/6c10f7ec426bd403d200874bf58d29548fdc860c))
* **widget:** display public error text for failed responses ([e3b2a95](https://github.com/www-zaq-ai/web_widget/commit/e3b2a9596e1bbc600638369fa87fb92709dd8829))
* **widget:** increase timeout to 5 mins ([30cd8b7](https://github.com/www-zaq-ai/web_widget/commit/30cd8b7d0fbd941cb212738cdf17a76276fd9ad8))
* **widget:** preserve chat on token renewal and stream message updates ([996832f](https://github.com/www-zaq-ai/web_widget/commit/996832f20dfb0ea2eb397d4742c5ac5086650efe))
* **widget:** prevent bootstrap race and fix cross-browser e2e tests ([ca9dcd2](https://github.com/www-zaq-ai/web_widget/commit/ca9dcd24b72e41b7f2b5da58ef505ee12e8d354b))
* **widget:** show connection status only while reconnecting ([f88410f](https://github.com/www-zaq-ai/web_widget/commit/f88410f10845aa8418dbf50db581ebe4576f3eb9))
* **widget:** timeout ([0576592](https://github.com/www-zaq-ai/web_widget/commit/057659247980be9bdcc5d5e3fc1a283ccfd1789b))


### Performance Improvements

* **live:** send deltas for cumulative response updates ([38817a0](https://github.com/www-zaq-ai/web_widget/commit/38817a012453c107e994e4e06a2298723c176011))
* **live:** send deltas for cumulative response updates ([6e86b9c](https://github.com/www-zaq-ai/web_widget/commit/6e86b9c209e6e6674ed707e1b0dee1b4ccd40f0e))


### Refactoring

* bind widget consumers to supervised configuration (ww-v12.2) ([26cd437](https://github.com/www-zaq-ai/web_widget/commit/26cd4374a0057aff45d643759c70a4970445b112))
* compose widget demo and package startup explicitly (ww-v12.3) ([aec4a77](https://github.com/www-zaq-ai/web_widget/commit/aec4a772ac44ca877c42f478aa022e302c899c5f))
* **widget:** rename allowed\_origins to allowed\_domains ([dbf5f52](https://github.com/www-zaq-ai/web_widget/commit/dbf5f52e95f0b0575ddc9c7dacf0841d7e0e236b))

## Changelog

Release Please maintains this file from conventional commits.
