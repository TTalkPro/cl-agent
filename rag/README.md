# RAG 模块

检索增强生成（Retrieval-Augmented Generation）模块。

## 目录结构

```
rag/
├── package-rag.lisp          # 包定义
├── utils.lisp                # 工具函数
├── splitter.lisp             # 文本分割器
├── embeddings.lisp           # 嵌入模型
├── vector-store.lisp         # 向量存储
├── pipeline.lisp             # RAG 管道
└── rag-plugin.lisp           # Kernel 插件集成
```

## RAG 流程

```
文档 → 分割 → 嵌入 → 向量存储
                         ↑
查询 → 嵌入 → 检索 ────────┘
                ↓
           相关上下文
                ↓
         LLM 生成回答
```

## 文本分割

### 基本分割器

```lisp
;; 按字符数分割
(defvar *splitter*
  (make-text-splitter
    :chunk-size 1000        ; 每块大小
    :chunk-overlap 200))    ; 重叠大小

(split-text *splitter* "长文本内容...")
;; => ("块1..." "块2..." "块3...")
```

### 分割策略

```lisp
;; 按段落分割
(make-text-splitter
  :strategy :paragraph
  :chunk-size 1000)

;; 按句子分割
(make-text-splitter
  :strategy :sentence
  :chunk-size 500)

;; 按标记分割（Markdown）
(make-text-splitter
  :strategy :markdown
  :chunk-size 1000)

;; 递归分割（先段落，再句子，最后字符）
(make-text-splitter
  :strategy :recursive
  :separators '("\n\n" "\n" ". " " ")
  :chunk-size 1000)
```

### 代码分割

```lisp
;; 按函数/类分割代码
(make-code-splitter
  :language :python
  :chunk-size 2000)

(make-code-splitter
  :language :lisp
  :chunk-size 1500)
```

## 嵌入模型

### 本地嵌入

```lisp
;; 使用本地模型
(defvar *embeddings*
  (make-local-embeddings
    :model "all-MiniLM-L6-v2"
    :dimension 384))

(embed *embeddings* "Hello, world!")
;; => #(0.123 0.456 ...)
```

### API 嵌入

```lisp
;; OpenAI 嵌入
(defvar *openai-embeddings*
  (make-embedding-client
    :provider :openai
    :model "text-embedding-3-small"
    :api-key (uiop:getenv "OPENAI_API_KEY")))

;; 智谱嵌入
(defvar *zhipu-embeddings*
  (make-embedding-client
    :provider :zhipu
    :model "embedding-2"
    :api-key (uiop:getenv "ZHIPU_API_KEY")))
```

### 批量嵌入

```lisp
;; 单次调用嵌入多个文本
(embed-batch *embeddings*
  '("文本1" "文本2" "文本3"))
;; => (#(...) #(...) #(...))
```

## 向量存储

### 内存向量存储

```lisp
(defvar *store* (make-vector-store))

;; 添加文档
(vector-store-add-document *store*
  "Common Lisp 是一种编程语言"
  (embed *embeddings* "Common Lisp 是一种编程语言")
  :metadata '(:source "intro.txt" :page 1))

;; 搜索
(vector-store-search *store*
  (embed *embeddings* "什么是 Lisp?")
  :top-k 5)
;; => ((0.92 . document1) (0.85 . document2) ...)
```

### 持久化向量存储

```lisp
;; SQLite 向量存储
(defvar *persistent-store*
  (make-persistent-vector-store
    :path "vectors.db"))

;; 保存
(vector-store-save *persistent-store*)

;; 加载
(vector-store-load *persistent-store*)
```

### 相似度计算

```lisp
;; 余弦相似度（默认）
(make-vector-store :similarity :cosine)

;; 欧氏距离
(make-vector-store :similarity :euclidean)

;; 点积
(make-vector-store :similarity :dot-product)
```

## 文档结构

```lisp
;; 文档对象
(defstruct document
  id          ; 唯一标识
  content     ; 文本内容
  embedding   ; 嵌入向量
  metadata)   ; 元数据

;; 创建文档
(make-document
  :id "doc-001"
  :content "文档内容..."
  :embedding #(0.1 0.2 ...)
  :metadata '(:source "file.txt"
              :created "2024-01-15"
              :author "作者"))
```

## RAG 管道

### 创建管道

```lisp
(defvar *rag*
  (make-rag-pipeline
    :embeddings-model *embeddings*
    :vector-store *store*
    :splitter *splitter*
    :llm-client *llm*))
```

### 索引文档

```lisp
;; 索引单个文档
(rag-index *rag* "文档内容..."
  :metadata '(:source "doc.txt"))

;; 索引文件
(rag-index-file *rag* "/path/to/document.txt")

;; 批量索引
(rag-index-directory *rag* "/path/to/docs/"
  :pattern "*.txt"
  :recursive t)
```

### 检索

```lisp
;; 检索相关文档
(rag-retrieve *rag* "什么是 Common Lisp?"
  :top-k 5
  :threshold 0.7)  ; 最小相似度阈值
;; => (document1 document2 ...)
```

### 查询

```lisp
;; 检索 + 生成
(rag-query *rag* "Common Lisp 有什么特点?"
  :top-k 5
  :system-prompt "基于提供的上下文回答问题。")
;; => "根据文档，Common Lisp 的特点包括..."
```

### 对话

```lisp
;; 多轮 RAG 对话
(rag-chat *rag*
  '((:role :user :content "什么是 SBCL?")
    (:role :assistant :content "SBCL 是...")
    (:role :user :content "它有什么优点?")))
```

## 与 Kernel 集成

### RAG Filter

```lisp
;; 创建 RAG 过滤器
(defvar *rag-filter*
  (make-rag-filter *rag*
    :top-k 5
    :inject-as :system))  ; 注入为系统消息

;; 添加到 Kernel
(defvar *kernel*
  (make-kernel
    :service *service*
    :filters (list *rag-filter*)))
```

### RAG Plugin

```lisp
;; 作为工具暴露
(defvar *rag-plugin*
  (make-rag-plugin *rag*
    :name "knowledge-base"
    :description "搜索知识库"))

(defvar *kernel*
  (make-kernel
    :service *service*
    :plugins (list *rag-plugin*)))

;; Agent 可以主动调用
(agent-chat *agent* "在知识库中搜索关于 Lisp 宏的信息")
```

## 高级配置

### 重排序

```lisp
;; 使用重排序模型提高精度
(make-rag-pipeline
  :embeddings-model *embeddings*
  :vector-store *store*
  :reranker (make-reranker
              :model "cross-encoder"
              :top-k 3))
```

### 混合检索

```lisp
;; 结合关键词和语义搜索
(make-rag-pipeline
  :retriever (make-hybrid-retriever
               :keyword-weight 0.3
               :semantic-weight 0.7))
```

### 上下文压缩

```lisp
;; 压缩检索到的上下文
(make-rag-pipeline
  :context-compressor (make-context-compressor
                        :max-tokens 2000
                        :strategy :extractive))
```

## 使用示例

### 文档问答系统

```lisp
;; 设置 RAG
(defvar *qa-rag*
  (make-rag-pipeline
    :embeddings-model (make-embedding-client :provider :openai)
    :vector-store (make-vector-store)
    :splitter (make-text-splitter :chunk-size 500)))

;; 索引文档
(rag-index-directory *qa-rag* "/docs/" :pattern "*.md")

;; 创建 QA Agent
(defvar *qa-agent*
  (make-kernel-agent
    (make-kernel
      :service *service*
      :filters (list (make-rag-filter *qa-rag*)))
    :system-prompt "基于文档回答问题。如果文档中没有相关信息，请说明。"))

;; 使用
(agent-chat *qa-agent* "如何配置系统?")
```

### 代码搜索

```lisp
;; 专门用于代码的 RAG
(defvar *code-rag*
  (make-rag-pipeline
    :embeddings-model *embeddings*
    :vector-store (make-vector-store)
    :splitter (make-code-splitter :language :lisp)))

;; 索引代码库
(rag-index-directory *code-rag* "/src/"
  :pattern "*.lisp"
  :recursive t)

;; 搜索代码
(rag-retrieve *code-rag* "HTTP 请求处理函数")
```

### 知识库 Agent

```lisp
;; 结合多个知识源
(defvar *docs-store* (make-vector-store))
(defvar *faq-store* (make-vector-store))

;; 索引不同来源
(rag-index *docs-rag* docs :metadata '(:type :documentation))
(rag-index *faq-rag* faqs :metadata '(:type :faq))

;; 合并检索
(defun multi-source-retrieve (query)
  (append
    (rag-retrieve *docs-rag* query :top-k 3)
    (rag-retrieve *faq-rag* query :top-k 2)))
```
