# PC 语音输入法 ASR 统一 Benchmark 报告

> 评测日期：2026-09-11；设备：Apple A18 Pro、8GB 统一内存、macOS 26.4；数据：10 条、5 个场景、共 227.256 秒。

## 结论

**建议将 Qwen3-ASR 0.6B MLX 4bit 作为 Apple Silicon 版 MVP 的首选 ASR，SeACo-Paraformer 作为 CPU 高吞吐备选。**

Qwen 在这套数据上的基础 MER 为 2.64%，为所有模型最低；中英混输和长句 MER 均为 0%。加入 Domain Vocabulary 后，热词召回率从 75.0% 提升到 87.5%，整体 MER 降到 2.26%。其主要代价是约 1.42GB Metal 峰值内存，且 MLX 路线只能直接覆盖 Apple Silicon。

SeACo 的整体 MER 为 5.40%，是最快的模型（RTF 0.023），但峰值 RSS 约 1.29GB，不轻。当前 funasr-onnx 接口对单个热词有 10 字符上限，本数据的英文热词召回率没有提升，因此现阶段不适合直接承担产品的个性化词汇卖点。

Sherpa 部署文件最小（约 202MB）、内存最低（约 428MB），但英文和专业词明显弱于 Qwen/SeACo，而且旧双语 checkpoint 的 token 表无法编码大部分专业英文热词。Nemotron 的新 revision 可以做真正的 Word Boosting，但启动约 41–44 秒、峰值 RSS 约 1.68GB，且基础 MER 11.81%，不建议成为当前 MVP 主模型。faster-whisper Base 的热词提示很强，但中文长录音出现重复性幻觉，基础 MER 18.09%，仅适合保留为 baseline。

## 基础准确率与性能

| 模型 | MER↓ | 中文 | 英文 | 混输 | 专业词 | 长句 | RTF↓ | 总推理时间 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| faster-whisper Base INT8 | 18.09% | 48.09% | 1.01% | 16.22% | 17.78% | 4.85% | 0.104 | 23.63s |
| Qwen3-ASR 0.6B MLX 4bit | 2.64% | 5.46% | 1.01% | 0.00% | 7.41% | 0.00% | 0.084 | 19.05s |
| SeACo-Paraformer backbone INT8 | 5.40% | 7.10% | 3.03% | 3.60% | 17.04% | 0.00% | 0.023 | 5.23s |
| Sherpa Zipformer zh-en encoder INT8 | 8.29% | 7.65% | 16.16% | 10.81% | 16.30% | 0.75% | 0.054 | 12.38s |
| Nemotron 3.5 ASR 0.6B Q8 | 11.81% | 14.21% | 3.03% | 20.72% | 22.96% | 4.10% | 0.105 | 23.76s |

中文列使用 CER 式单字 token，英文列使用 WER，其他场景使用“中文按字、英文按词”的 MER。所有指标忽略大小写和标点，但没有把“11”与“十一”作语义等价替换。

## 热词 A/B

| 模型 | 无热词召回 | 开热词召回 | 变化 | 无热词 MER | 开热词 MER | 结论 |
|---|---:|---:|---:|---:|---:|---|
| faster-whisper Base INT8 | 62.5% | 95.8% | +33.3pp | 18.09% | 18.84% | Hint 显著提升召回，但小幅伤害整体 MER |
| Qwen3-ASR 0.6B MLX 4bit | 75.0% | 87.5% | +12.5pp | 2.64% | 2.26% | 召回和整体准确率同时改善 |
| SeACo-Paraformer backbone INT8 | 41.7% | 41.7% | +0.0pp | 5.40% | 5.53% | 当前接口对长英文热词受限，没有收益 |
| Sherpa Zipformer zh-en encoder INT8 | 50.0% | 41.7% | -8.3pp | 8.29% | 8.54% | 多数英文词 OOV，且热词模式需要更慢的 beam search |
| Nemotron 3.5 ASR 0.6B Q8 | 29.2% | 70.8% | +41.7pp | 11.81% | 11.68% | Word Boosting 有效，但术语句仍有明显错词 |

## 资源与工程指标

| 模型 | 计算路线 | 部署体积 | 加载/就绪时间 | 峰值内存 | 延迟中位数 | 延迟 P95 | RTF P95 | 标点数量 F1* |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| faster-whisper Base INT8 | CPU / CTranslate2 INT8 | 141MB | 0.31s | 687MB | 1.95s | 4.10s | 0.125 | 83.8% |
| Qwen3-ASR 0.6B MLX 4bit | Metal / MLX 4bit | 680MB | 1.45s | 1415MB | 1.75s | 2.87s | 0.094 | 93.8% |
| SeACo-Paraformer backbone INT8 | CPU / ONNX Runtime, 4 threads | 863MB | 1.81s | 1287MB | 0.39s | 1.14s | 0.088 | 0.0% |
| Sherpa Zipformer zh-en encoder INT8 | CPU / ONNX Runtime, 4 threads | 199MB | 0.36s | 428MB | 1.17s | 1.89s | 0.057 | 0.0% |
| Nemotron 3.5 ASR 0.6B Q8 | Metal / GGML Q8 | 708MB | 43.91s | 1685MB | 2.09s | 3.89s | 0.131 | 93.1% |

\* 标点数量 F1 只比较各类标点的数量，不验证具体落点，只用于区分“是否输出标点”，不是完整的标点准确率。Qwen 的内存值来自 MLX Metal peak memory；其他模型为进程峰值 RSS。Nemotron 就绪时间包括 Metal pipeline 编译与 runtime warm-up。

## 逐条基础转录与耗时

### daily_zh_01 · daily_zh

**参考文本：** 今天洛杉矶停电了，就那一个街区，从下午三点到现在11点，8个小时都没电，好烦啊，这么热。

| 模型 | 推理时间 | RTF | 转录文本 |
|---|---:|---:|---|
| faster-whisper Base INT8 | 1.305s | 0.124 | 今天路上机停电了,就那一个结局,从下午3点到现在11点,8个小时都没电,好烦啊这么热 |
| Qwen3-ASR 0.6B MLX 4bit | 1.005s | 0.096 | 今天洛杉矶停电了，就那一个街区，从下午三点到现在十一点，八个小时都没电，好烦啊！这么热。 |
| SeACo-Paraformer backbone INT8 | 1.517s | 0.144 | 今天洛杉矶停电了就那一个街区从下午三点到现在十一点八个小时都没电好烦啊这么热 |
| Sherpa Zipformer zh-en encoder INT8 | 0.587s | 0.056 | 今天洛杉矶停电了就那一个街区从下午三点到现在十一点八个小时都没电好烦啊这么热 |
| Nemotron 3.5 ASR 0.6B Q8 | 1.539s | 0.146 | 今天露山器停电了, 就那一个街区从下午三点到现在十一点八个小时都没电, 好烦啊这么热。 |

### daily_zh_02 · daily_zh

**参考文本：** 今天早上，我去超市买了点食物，买了1磅牛肉，花了10美刀，可能是部位的问题吧，没想到这么贵，折合人民币70块钱呢。然后我还买了一些，呃，我想想是啥呢，啊，对了，是柚子。因为呢，柚子本身糖分低，升糖指数也低啊，而且也不难吃，也可以说是很好吃，所以呢我买了五个，大概6刀吧好像，感觉有点小贵。然后我中午就自己做的饭，煎的两个鸡排，还挺好吃的，哈哈哈。

| 模型 | 推理时间 | RTF | 转录文本 |
|---|---:|---:|---|
| faster-whisper Base INT8 | 4.608s | 0.118 | 今天早上我去超市买了点食物,买了一帮牛肉,花了十美道,可能是不胃的问题吧,没想到这么贵,只喝人民币70块钱呢,然后我还买了一些,我想想是啥呢,对了,是柚子,因为柚子本身糖分低,生糖纸树也低啊,而是也不难吃,也可以说是很好吃,所以呢我买了五个,大概六十块钱,然后我还买了一些,我想想是啥呢,对了,是柚子,因为呢柚子本身糖分低,生糖纸树也低,而是也不难吃,也可以说是很好吃,所以呢我买了五个,大概六十块钱,六刀吧,好像,感觉有点小贵,然后我中午就自己做的饭,煎的两个鸡排还挺好吃的,哈哈 |
| Qwen3-ASR 0.6B MLX 4bit | 3.154s | 0.080 | 今天早上，我去超市买了点食物，买了一磅牛肉，花了十美刀，可能是部位的问题吧，没想到这么贵，折合人民币七十块钱呢。然后我还买了一些，呃，我想想是啥呢？啊，对了，是柚子。因为呢，柚子本身糖分低，升糖指数也低啊，而且也也不难吃，也可以说是很好吃。所以呢，我买了五个，大概六刀吧，好像感觉有点小贵。然后我中午就自己做的饭，煎了两个鸡排，还挺好吃的，哈哈哈。 |
| SeACo-Paraformer backbone INT8 | 0.682s | 0.017 | 今天早上我去超市买了点食物买了一磅牛肉花了十美刀可能是部位的问题吧没想到这么贵折合人民币七十块钱呢而后我还买了一些呃我想想是啥呢啊对了是柚子因为呢柚子本身糖分低升糖指数也低呀而是也也不难吃也可以说是很好吃所以呢我买了五个大概六刀吧好像感觉有点小贵然后我中午就自己做的饭煎了两个鸡排还挺好吃的哈哈哈 |
| Sherpa Zipformer zh-en encoder INT8 | 2.013s | 0.051 | 今天早上我去超市买了点食物买了一磅牛肉花了十枚刀可能是部位的问题吧没想到这么贵折合人民币七十块钱呢然后我还买了一些呃我想想是啥呢啊对了是柚子因为呢柚子本身糖分低升糖指数也低呀而是也也不难吃也可以说是很好吃所以呢我买了五个大概六刀吧好像感觉有点小贵然后我中午就自己做的饭煎了两个鸡排还挺好吃的哈哈 |
| Nemotron 3.5 ASR 0.6B Q8 | 4.406s | 0.112 | 今天早上我去超市买了点食物, 买了一棒牛肉, 花了十美刀, 可能是部位的问题吧, 没想到这么贵, 这喝人民币七十块钱呢。 然后我还买了一些呃我想象是啥呢? 啊, 对了, 是柚子, 因为呢柚子本身糖分低, 生糖指数也低呀, 而是也也不难吃, 也可以说是很好吃。 所以呢, 我买了五个, 大概六到半好像感觉有点小贵, 然后我中午就自己做的饭, 坚到两个 G 牌还挺好吃的, 哈哈。 |

### daily_en_01 · daily_en

**参考文本：** I need to finish a few things before dinner tonight. First, I want to reply to some messages, and then I need to organize my notes for tomorrow. If I still have time, I’ll probably go to the grocery store and buy some food for the next few days.

| 模型 | 推理时间 | RTF | 转录文本 |
|---|---:|---:|---|
| faster-whisper Base INT8 | 1.635s | 0.080 | I need to finish a few things before dinner tonight. First, I want to reply to some messages, and then I need to organize my notes for tomorrow. If I still have time, I will probably go to the grocery store and buy some food for the next few days. |
| Qwen3-ASR 0.6B MLX 4bit | 1.615s | 0.079 | I need to finish a few things before dinner tonight. First, I want to reply to some messages, and then I need to organize my notes for tomorrow. If I still have time, I will probably go to the grocery store and buy some food for the next few days. |
| SeACo-Paraformer backbone INT8 | 0.344s | 0.017 | i need to finish a few things before dinner tonight first i want to reply to some messages and then i need to organize my nose for tomorrow if i still have time i will probably go to the grocery store and buy some food for the next few days |
| Sherpa Zipformer zh-en encoder INT8 | 1.077s | 0.053 | I NEED TO FINISH A FEW THINGS BEFORE DINNA TONIGHT FIRST I WANT TO REPLY TO SOME MESSAGES AND THEN I NEED TO ORGANIZE MY NOSE FOR TOMORROW IF I STILL HAVE TIME I WILL PROBABLY GO TO THE GROSS RESTORE AND BY SOME FOOL FOR THE NEXT FEW DAYS |
| Nemotron 3.5 ASR 0.6B Q8 | 2.053s | 0.100 | I need to finish a few scenes before dinner tonight first. I want to reply to some messages, and then I need to organize my notes for tomorrow. If I still have time, I will probably go to the grocery store and buy some food for the next few days. |

### daily_en_02 · daily_en

**参考文本：** I’ve been trying to use my computer more efficiently during the day. Instead of switching between too many apps, I usually keep my browser, notes, and calendar open at the same time. This makes it easier to find information and keep track of what I need to do.

| 模型 | 推理时间 | RTF | 转录文本 |
|---|---:|---:|---|
| faster-whisper Base INT8 | 1.643s | 0.076 | I've been trying to use my computer more efficiently during the day. Instead of switching between too many apps, I usually keep my browser, notes and calendar open at the same time. This makes it easier to find information and keep track of what I need to do. |
| Qwen3-ASR 0.6B MLX 4bit | 1.789s | 0.082 | I've been trying to use my computer more efficiently during the day. Instead of switching between too many apps, I usually keep my browser, notes, and calendar open at the same time. This makes it easier to find information and keep track of what I need to do. |
| SeACo-Paraformer backbone INT8 | 0.368s | 0.017 | i've been trying to use my computer more efficiently during the day instead of switching between too many apps i usually keep my browser nose and calendar open at the same time this makes it easier to find information and keep track of what i need to do |
| Sherpa Zipformer zh-en encoder INT8 | 1.172s | 0.054 | FBIN TRYING TO USE MY COMPUTER MORE EFFICIENTLY THERE IN THE DAY INSTEAD OF SWEACHING BETWEEN TOO MANY APPS ARE USUALLY KEEP MY BROWSER KNOWS AND CALENDAR OPEN AT THE SAME TIME THIS MIX IT EASIER TO FIND INFORMATION AND KEEP TRACK OF WHAT I NEED TO DO |
| Nemotron 3.5 ASR 0.6B Q8 | 2.134s | 0.098 | I've been trying to use my computer more efficiently during the day instead of switching between too many apps I usually keep my browser, nose, and calendar open at the same time. This makes it easier to find information and keep track of what I need to do. |

### mixed_01 · mixed

**参考文本：** 我今天想先把这个 project 的基本 structure 整理一下，然后检查一下 current version 还有哪些问题。如果时间够的话，我会再跑一次 benchmark，看看 model 的 accuracy 和 latency 有没有变化。

| 模型 | 推理时间 | RTF | 转录文本 |
|---|---:|---:|---|
| faster-whisper Base INT8 | 1.627s | 0.111 | 我今天想先把 this project 的基本 structure 整理一下然后检查一下 Korean version 还有哪些问题如果时间够的话,我会再跑一次 benchmark看看 model 的 accuracy 和 latency 有没有变化 |
| Qwen3-ASR 0.6B MLX 4bit | 1.347s | 0.092 | 我今天想先把这个 project 的基本 structure 整理一下，然后检查一下 current version 还有哪些问题。如果时间够的话，我会再跑一次 benchmark，看看 model 的 accuracy 和 latency 有没有变化。 |
| SeACo-Paraformer backbone INT8 | 0.248s | 0.017 | 我今天想先把这个project的基本structure整理一下然后检查一下current version还有哪些问题如果时间够的话我会再跑一次bashma看看model的accurancy和latency有没有变化 |
| Sherpa Zipformer zh-en encoder INT8 | 0.800s | 0.055 | 我今天想先把这个 PROJECT基本 STRUCTURE整理一下然后检查一下柯瑞的 VISION还有哪些问题如果时间够的话我会再跑一次 BESHMAR看看 MODEL的 AKRAINES和 LINCY有没有变化 |
| Nemotron 3.5 ASR 0.6B Q8 | 1.225s | 0.084 | 我今天想先把这个 projec的基本 strun 的 version, 还有哪些问题。 如果时间够的话, 我会再跑一次 BACMR, 看看 MOLO 的 accurancy和 latnecy有没有变化。 |

### mixed_02 · mixed

**参考文本：** 这个 feature 现在的 user experience 还不太稳定，主要问题是 response speed 有点慢，而且有时候会识别错一些 English words。下一步我想先优化 inference process，再检查 memory usage 和 overall performance。

| 模型 | 推理时间 | RTF | 转录文本 |
|---|---:|---:|---|
| faster-whisper Base INT8 | 1.653s | 0.099 | 這個 feature 現在的 user experience 還不太穩定主要問題是 response speed 有點慢而且有時候會識別錯一些 English words下一步我想先優化 inference process再檢查 memory usage 和 overall performance |
| Qwen3-ASR 0.6B MLX 4bit | 1.467s | 0.088 | 这个 feature 现在的 user experience 还不太稳定，主要问题是 response speed 有点慢，而且有时候会识别错一些 English words。下一步我想先优化 inference process，再检查 memory usage 和 overall performance。 |
| SeACo-Paraformer backbone INT8 | 0.281s | 0.017 | 这个feature现在的user experience还不太稳定主要问题是respond speed有点慢而且有时候会识别错一些english words下一步我想先优化influence process再检查memory usage和overall performance |
| Sherpa Zipformer zh-en encoder INT8 | 0.923s | 0.056 | 这个 FISHER现在的 USE EXPERIENCE还不太稳定主要问题是 RESPOND SPEED有点慢而且有时候会识别错一些 ENGLISH WORDS下一步我想现优化 INFERENCE PROCESS再检查 MEMORY USAGE和 OVERALL PERFORMANCE |
| Nemotron 3.5 ASR 0.6B Q8 | 1.739s | 0.105 | 这个 Father 现在的 UC Experence 还不太稳定, 主要问题是 Response speed 有点慢, 而且有时候会识别错一些 English Word, 下一步我想先优化 Influence process 再检查 Memory Usage 和 OverO Performance。 |

### terms_01 · terminology

**参考文本：** 我最近在测试 Paimon Desktop，主要会用到 Playwright、MCP、FastAPI 和 Electron。语音模块这边我想比较 Whisper、Silero VAD 和其他本地 ASR 模型的效果，重点看 hotword support、inference latency 和 memory usage。如果后面加入 agent orchestration，我还需要测试不同 tool calling 场景下的稳定性。

| 模型 | 推理时间 | RTF | 转录文本 |
|---|---:|---:|---|
| faster-whisper Base INT8 | 2.484s | 0.088 | 我最近在测试拍盟desktops主要会用到playride mcpfast api和electron云英模块这边我想比较whispersiliger VAD和其他本DASR模型的效果重点看hardware supportinference latency和memory usage如果后面加入 agent or chestrition我还需要测试不同图扣领场景下的稳定性 |
| Qwen3-ASR 0.6B MLX 4bit | 2.267s | 0.080 | 我最近在测试派蒙（desktop），主要会用到PlayReady MCP、Fast API和Electron。语音模块这边，我想比较Whisper、Celestial VAD和其他本地ASR模型的效果。重点看Hardware Support、Inference Latency和Memory Usage。如果后面加入Agent orchestration，我还需要测试不同To Coding场景下的稳定性。 |
| SeACo-Paraformer backbone INT8 | 0.473s | 0.017 | 我最近在测试派蒙desk top主要会用到play right MCP fast API和electrum语音模块这边我想比较whisper seligial VAD和其他本地ASR模型的效果重点看hodwd cort influence latency和memory usage如果后面加入agent orchestration我还需要测试不同to coding场景下的稳定性 |
| Sherpa Zipformer zh-en encoder INT8 | 1.530s | 0.054 | 我最近在测试拍萌 DESKTOP主要会用到 PLAYWRITE MCP FAST API和 ELECTRON语音模块这边我想比较 WHISPER S LEIGERAL VAD和其他本地 ASR模型的效果重点看 HOLOW SUPPORT INFLUENCE LATENCY和 MEMORY USAGE如果后面加入 AGENT ORCHESTRATION我还需要测试不同涂口顶场景下的稳定性 |
| Nemotron 3.5 ASR 0.6B Q8 | 2.899s | 0.103 | 我最近在测试派盟 Desktop主要会用到 Playride MCP Fast API 和 Electro, 语音模块这边我想比较 Wisper C LegalVAD 和其他本地 ASR 模型的效果, 重点看 Hall world support in latency和 Memory Usage。 如果后面加入 ARC Orchestration, 我还需要测试不同 tQ 领场景下的稳定性。 |

### terms_02 · terminology

**参考文本：** 这节课主要讨论 Transformer 的推理优化，包括 KV Cache、Paged Attention、Flash Attention 和 Continuous Batching。除此之外，我还想比较 prefill 和 decode 阶段的性能差异，以及 Tensor Parallel、Expert Parallel 和 Prefix Caching 对 inference throughput 的影响。

| 模型 | 推理时间 | RTF | 转录文本 |
|---|---:|---:|---|
| faster-whisper Base INT8 | 2.251s | 0.108 | 这些课主要讨论 Transformer 的推理优化,包括 KV Cash, Page Attention, Flash Attention,和 Continuous Batching,除此之外,我还想比较 Preview 和 Decode 阶段的性能差异,以及 Tensor Parallel, Expert Parallel,和 Prefix Caching,对 inference throughput 的影响。 |
| Qwen3-ASR 0.6B MLX 4bit | 1.712s | 0.082 | 这节课主要讨论Transformer的推理优化，包括KV Cache、Page Attention、Flash Attention和Continuous Batching。除此之外，我还想比较Prefill和Decode阶段的性能差异，以及Tensor Parallel、Expert Parallel和Prefix Caching对Inference throughput的影响。 |
| SeACo-Paraformer backbone INT8 | 0.378s | 0.018 | 这节课主要讨论transformer的推理优化包括KV cash pitch attention flash attention和continuous spechch除此之外我还想比较prefuil和decode阶段的性能差异以及t ancer parallel expert parallel和prefix cash对influence throughput的影响 |
| Sherpa Zipformer zh-en encoder INT8 | 1.169s | 0.056 | 这节课只要讨论 TRANSFORMER的推理优化包括 KV CASH PICTURE ATTENTION FLASH ATTENTION和 CONTINUOUS BATCHING除此之外我还想比较 PREFER和 DECL的阶段的性能差异以及 PARALLEL EXPERT PARALLEL和 PREFIX CASHING对 INFERENCE THROUGH PUT的影响 |
| Nemotron 3.5 ASR 0.6B Q8 | 1.955s | 0.094 | 这些课主要讨论 Transform 的推理优化, 包括 KV Cash Pache Atention, Flash attention和 continuous batching。 除此之外, 我还想比较 Prefayo和跌扣的阶段的性能差异, 以及探索 PARO EXPAL 和 Prefix Caching 对 Incrasse RPOT 影响。 |

### long_normal · long_sentence

**参考文本：** 我觉得这个方案目前还有几个比较明显的问题。第一个是模型加载之后占用的内存有点高，第二个是用户停止说话之后还需要等待一段时间才能看到最终结果，第三个是中英文混合输入的时候偶尔会出现识别错误。所以我下一步想先测试不同模型的准确率和推理速度，再根据实际结果决定要不要继续优化现在的方案。

| 模型 | 推理时间 | RTF | 转录文本 |
|---|---:|---:|---|
| faster-whisper Base INT8 | 3.469s | 0.110 | 我觉得这个防暗目前还有几个比较明显的问题第一个是模型加载之后占用的内存有点高第二个是用户停止说话之后还需要等待一段时间才能看到最终结果第三个是中英文混额输入的时候偶尔会出现实别错误所以我下一步想先测试不同模型的准确率和推理速度在根据实际结果决定要不要继续优化现在的防暗 |
| Qwen3-ASR 0.6B MLX 4bit | 2.526s | 0.080 | 我觉得这个方案目前还有几个比较明显的问题：，第一个是模型加载之后占用的内存有点高；，第二个是用户停止说话之后，还需要等待一段时间才能看到最终结果；，第三个是中英文混合输入的时候，偶尔会出现识别错误。所以我下一步想先测试不同模型的准确率和推理速度，再根据实际结果决定要不要继续优化现在的方案。 |
| SeACo-Paraformer backbone INT8 | 0.547s | 0.017 | 我觉得这个方案目前还有几个比较明显的问题第一个是模型加载之后占用的内存有点高第二个是用户停止说话之后还需要等待一段时间才能看到最终结果第三个是中英文混合输入的时候偶尔会出现识别错误所以我下一步想先测试不同模型的准确率和推理速度再根据实际结果决定要不要继续优化现在的方案 |
| Sherpa Zipformer zh-en encoder INT8 | 1.734s | 0.055 | 我觉得这个方案目前还有几个比较明显的问题第一个是模型加载之后占用的内存有点高第二个是用户停止说话之后还需要等待一段时间才能看到最终结果第三个是中英文混合输入的时候偶尔会出现识别错误所以我下一步想先测试不同模型的准确率和推理速度再根据实际结果决定要不要继续优化现在的方案 |
| Nemotron 3.5 ASR 0.6B Q8 | 3.256s | 0.103 | 我觉得这个方案目前还有几个比较明显的问题。 第一个是模型加载之后摘用的内存有点高, 第二个是用户停止说话之后, 还需要等大一段时间才能看到最终结果。 第三个是中英文混合输入的时候, 偶尔会出现识别错误。 所以我下一步想先测试不同模型的准确率和推理速度, 再根据实际结果决定要不要继续优化现在的方案。 |

### long_fast · long_sentence

**参考文本：** 我觉得这个方案目前还有几个比较明显的问题。第一个是模型加载之后占用的内存有点高，第二个是用户停止说话之后还需要等待一段时间才能看到最终结果，第三个是中英文混合输入的时候偶尔会出现识别错误。所以我下一步想先测试不同模型的准确率和推理速度，再根据实际结果决定要不要继续优化现在的方案。

| 模型 | 推理时间 | RTF | 转录文本 |
|---|---:|---:|---|
| faster-whisper Base INT8 | 2.956s | 0.126 | 我觉得这个防暗目前还有几个比较明显的问题第一个是模型加在之后,占用的内存有点高第二个是用户停止说话之后还需要等大一段时间才能看到最终结果第三个是中英文混合输入的时候,偶尔会出现识别错误所以我下一步想先测试不同模型的准确率和推理速度再根据实际结果决定要不要继续优化现在的防暗 |
| Qwen3-ASR 0.6B MLX 4bit | 2.166s | 0.092 | 我觉得这个方案目前还有几个比较明显的问题：，第一个是模型加载之后占用的内存有点高；，第二个是用户停止说话之后还需要等待一段时间才能看到最终结果；，第三个是中英文混合输入的时候偶尔会出现识别错误。所以我下一步想先测试不同模型的准确率和推理速度，再根据实际结果决定要不要继续优化现在的方案。 |
| SeACo-Paraformer backbone INT8 | 0.395s | 0.017 | 我觉得这个方案目前还有几个比较明显的问题第一个是模型加载之后占用的内存有点高第二个是用户停止说话之后还需要等待一段时间才能看到最终结果第三个是中英文混合输入的时候偶尔会出现识别错误所以我下一步想先测试不同模型的准确率和推理速度再根据实际结果决定要不要继续优化现在的方案 |
| Sherpa Zipformer zh-en encoder INT8 | 1.378s | 0.059 | 我觉得这个方案目前还有几个比较明显的问题第一个是模型加载之后占用的内存有点高第二个是用户停止说话之后还需要等大一段时间才能看到最终结果第三个是中英文混合输入的时候偶尔会出现识别错误所以我下一步想先测试不透模型的准确率和推理速度再根据实际结果决定要不要继续优化现在的方案 |
| Nemotron 3.5 ASR 0.6B Q8 | 2.555s | 0.109 | 我觉得这个防暗目前还有几个比较明显的问题, 第一个是模型加载之后, 占用的内存有点高。 第二个是用户停止说话之后还需要等大一段时间才能看到最终结果。 第三个是中英文混合输入的时候, 偶尔会出现识别错误。 所以我下一部分想先测试不透模型的准确率和推理速度, 再给实际结果决定要不要继续优化现代的方案。 |

## 专业词热词模式转录

### terms_01

**热词：** Paimon Desktop, Playwright, MCP, FastAPI, Electron, Whisper, Silero VAD, ASR, hotword support, inference latency, memory usage, agent orchestration, tool calling

| 模型 | 推理时间 | 转录文本 |
|---|---:|---|
| faster-whisper Base INT8 | 2.049s | 我最近在測試 Paimon Desktop 主要會用到 Playwright MCP FastAPI Electron語音模塊這邊我想比較 Whisper Silero VAD和其他本地 ASR模型的效果終點看 hotword support inference latency和 memory usage如果後面加入 agent orchestration 我還需要測試不同 途 calling場景下的穩定性 |
| Qwen3-ASR 0.6B MLX 4bit | 2.539s | 我最近在测试派蒙 Desktop，主要会用到 Playwright MCP、 Fast API 和 Electron。语音模块这边，我想比较 Whisper、 Silero VAD 和其他本地 ASR 模型的效果。重点看 Hotword Support、 inference latency 和 memory usage。如果后面加入 Agent Orchestration，我还需要测试不同 To Coding 场景下的稳定性。 |
| SeACo-Paraformer backbone INT8 | 0.457s | 我最近在测试派蒙desk top主要会用到play right MCP fast API和electrum语音模块这边我想比较whisper seligial VAD和其他本地ASR模型的效果重点看hodwd cort influence latency和memory usage如果后面加入agent orchestration我还需要测试不同to coding场景下的稳定性 |
| Sherpa Zipformer zh-en encoder INT8 | 4.339s | 我最近在测试拍萌 DESKTOP主要会用到 PLAYWRITE MCP FAST API和 ELECTION语音模块这边我想比较 WHISPER SYLLIDER VAD和其他本地 ASR模型的效果重点看 HOLOW SUPPORT INFLUENCE LATENCY和 MEMORY USAGE如果后面加入 AGENT ORCHESTRATION我还需要测试不同涂口顶场景下的稳定性 |
| Nemotron 3.5 ASR 0.6B Q8 | 3.827s | 我最近在测试派盟 Desk tool 主要会用到 Playwright MCP FastAPI 和 Electron 语音模块这边我想比较 Whisper Silero VAD 和其他本地 ASR 模型的效果。 重点看 hotword support inference latency和 memory usage。 如果后面加入 ASRO 我还需要测试不同 tool calling 场景下的稳定性。 |

### terms_02

**热词：** Transformer, KV Cache, Paged Attention, Flash Attention, Continuous Batching, prefill, decode, Tensor Parallel, Expert Parallel, Prefix Caching, inference throughput

| 模型 | 推理时间 | 转录文本 |
|---|---:|---|
| faster-whisper Base INT8 | 2.033s | 這些客主要討論 Transformer 的推理優化包括 KV Cache Paged Attention Flash Attention 和 Continuous Batching除此之外,我還想比較 prefill和 decode階段的性能差異以及 Tensor Parallel Expert Parallel 和 Prefix Caching對 inference throughput 的影響 |
| Qwen3-ASR 0.6B MLX 4bit | 1.847s | 这节课主要讨论Transformer的推理优化，包括KV Cache、Page Attention、Flash Attention和Continuous Batching。除此之外，我还想比较Prefill和Decode阶段的性能差异，以及Tensor Parallel、Expert Parallel和Prefix Caching对Inference throughput的影响。 |
| SeACo-Paraformer backbone INT8 | 0.347s | 这节课主要讨论transformer的推理优化包括KV cash pitch attention flash attention和continuous spechch除此之外我还想比较prefuil和decode阶段的性能差异以及t ans er parallel expert parallel和prefix cash对influence throughput的影响 |
| Sherpa Zipformer zh-en encoder INT8 | 3.386s | 这节课只要讨论 TRANSFORMER的推理优化包括 KV CASH PICTURE ATTENTION FLASH ATTENTION和 CONTINUOUS BATCHING除此之外我还想比较 PREFER和抵扣的阶段的性能差异以及 POWERLOXBOARD PARALLEL和 PREFIX CASHING对 INFERENCE THROUGH PUT的影响 |
| Nemotron 3.5 ASR 0.6B Q8 | 2.347s | 这些课主要讨论 Transformer 的推理优化, 包括 KV Cache A Tensor Parallel Paged Attention和 Paged Attention阶段的性能差异, 以及探索 Paged Attention 和 Prefix Caching 对 inference throughput影响 |

## 局限与下一步产品决策

- 本结论只覆盖当前 10 条、单一设备和当前录音人，用于 PoC 选型，不能外推为通用模型排名。
- 现在可以做出 Apple Silicon 路线的决策：优先围绕 Qwen 做输入法 PoC。
- Windows 不能直接使用 MLX，因此在定最终 MVP 之前，需验证 Qwen 的 Windows 推理路线，或接受 macOS 与 Windows 使用不同 runtime。
- 如果必须单一 CPU 模型覆盖双平台，当前数据更支持 SeACo，但必须先解决英文热词长度限制，否则它与产品的核心差异化能力冲突。

## 可复现性

评测入口为 `python -m benchmark.run --backend <backend>`，数据清单在 `benchmark/manifest.yaml`，每次运行的原始转录保存在对应结果目录的 `predictions.jsonl`，汇总指标保存在 `metrics.json`。
