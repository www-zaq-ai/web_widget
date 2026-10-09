# Changelog

## [0.2.0](https://github.com/www-zaq-ai/web_widget/compare/v0.1.0...v0.2.0) (2026-10-09)


### Features

* add container embedding, asset installer, and Markdown rendering ([ceb7155](https://github.com/www-zaq-ai/web_widget/commit/ceb7155ddfdb6018871da644db6c7003310e8ba9))
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
* **integration:** add jwt-authenticated chat and history restoration ([e147a51](https://github.com/www-zaq-ai/web_widget/commit/e147a5101808021fca8e8c494fb4c4e573887d77))
* **integration:** add zaq runtime adapter and automatic iframe embedding ([2874770](https://github.com/www-zaq-ai/web_widget/commit/287477041079dbb8aefb9402e85358ee1ac42eeb))
* **router:** add router macro ([c5126f3](https://github.com/www-zaq-ai/web_widget/commit/c5126f3f7f23dd2ba08b1b7447240dfeba2029df))
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

* **authentication:** preserve bindings and reconnect recovery (ww-ocy) ([9c86b59](https://github.com/www-zaq-ai/web_widget/commit/9c86b592ec958e49c9d7ff86f0c354f527b0a52a))
* **authentication:** restore recovery ownership and readiness ([2830959](https://github.com/www-zaq-ai/web_widget/commit/2830959595935d038710486f1cd77e2fae79adf3))
* **authentication:** restore selected conversation on reconnect (ww-2mu) ([5ff8b5e](https://github.com/www-zaq-ai/web_widget/commit/5ff8b5ec4f8e801c47925aa985f9b01bae4486dc))
* **authentication:** security hardening ([df9b169](https://github.com/www-zaq-ai/web_widget/commit/df9b1698c486fd4d690d3a70c95c8f032cfdec2e))
* **e2e:** remove the header assertion ([2b60950](https://github.com/www-zaq-ai/web_widget/commit/2b60950cfd4ae0094b812766eb1f975e92bc83f9))
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

* **widget:** rename allowed\_origins to allowed\_domains ([dbf5f52](https://github.com/www-zaq-ai/web_widget/commit/dbf5f52e95f0b0575ddc9c7dacf0841d7e0e236b))

## Changelog

Release Please maintains this file from conventional commits.
