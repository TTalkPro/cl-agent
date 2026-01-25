# Plugin 模块

增强工具系统模块，提供安全策略、弹性模式和内置工具。

## 目录结构

```
plugin/
├── package.lisp              # 包定义
├── security.lisp             # 安全策略
├── resilience.lisp           # 弹性模式
├── builtin/                  # 内置工具
│   ├── file.lisp            # 文件操作
│   ├── http.lisp            # HTTP 请求
│   ├── shell.lisp           # Shell 执行
│   └── utility.lisp         # 实用工具
└── all.lisp                 # 汇总导出
```

## 内置插件

### File Plugin

文件系统操作：

```lisp
;; 加载插件
(use-plugin 'file-plugin)

;; 可用工具
;; file-read    - 读取文件内容
;; file-write   - 写入文件
;; file-delete  - 删除文件
;; file-list    - 列出目录内容
;; file-exists  - 检查文件是否存在
;; file-info    - 获取文件信息

;; 示例
(file-read "/path/to/file.txt")
(file-write "/path/to/file.txt" "内容")
(file-list "/path/to/directory")
```

### HTTP Plugin

HTTP 请求工具：

```lisp
(use-plugin 'http-plugin)

;; 可用工具
;; http-get     - GET 请求
;; http-post    - POST 请求
;; http-put     - PUT 请求
;; http-delete  - DELETE 请求

;; 示例
(http-get "https://api.example.com/data")
(http-post "https://api.example.com/data"
  :body '(:key "value")
  :headers '(("Content-Type" . "application/json")))
```

### Shell Plugin

Shell 命令执行（沙盒化）：

```lisp
(use-plugin 'shell-plugin)

;; 可用工具
;; shell-execute - 执行 Shell 命令

;; 示例（受安全策略限制）
(shell-execute "ls -la")
(shell-execute "echo 'Hello'")

;; 配置允许的命令
(configure-shell-plugin
  :allowed-commands '("ls" "cat" "echo" "grep")
  :blocked-commands '("rm" "sudo" "chmod"))
```

### Utility Plugin

通用工具：

```lisp
(use-plugin 'utility-plugin)

;; 可用工具
;; calculate    - 数学计算
;; format-date  - 日期格式化
;; json-parse   - JSON 解析
;; json-format  - JSON 格式化
;; uuid-generate - 生成 UUID
;; base64-encode - Base64 编码
;; base64-decode - Base64 解码

;; 示例
(calculate "(+ 1 2 3)")
(format-date (get-universal-time) "YYYY-MM-DD")
(json-parse "{\"key\": \"value\"}")
```

## 安全策略

### 创建安全策略

```lisp
(defvar *policy*
  (make-security-policy
    :rate-limit 60              ; 每分钟最大请求数
    :timeout 30                 ; 超时时间（秒）
    :max-input-size 10000       ; 最大输入大小（字符）
    :sandbox-enabled t          ; 启用沙盒
    :input-validation-fn #'validate-input))

;; 应用到插件
(apply-security-policy 'file-plugin *policy*)
```

### 速率限制

```lisp
(defvar *rate-limiter*
  (make-rate-limiter
    :requests-per-minute 60
    :burst-size 10))

(with-rate-limit (*rate-limiter*)
  (execute-tool ...))
```

### 输入验证

```lisp
;; 定义验证函数
(defun validate-file-path (path)
  (and (stringp path)
       (not (search ".." path))           ; 防止路径遍历
       (not (search "~" path))            ; 禁止 home 目录
       (< (length path) 256)))            ; 长度限制

;; 应用验证
(make-security-policy
  :input-validation-fn #'validate-file-path)
```

### 沙盒执行

```lisp
;; 配置沙盒
(defvar *sandbox*
  (make-sandbox
    :allowed-paths '("/tmp/" "/data/")    ; 允许访问的路径
    :blocked-paths '("/etc/" "/root/")    ; 禁止访问的路径
    :max-memory 100000000                  ; 最大内存（字节）
    :max-time 60))                         ; 最大执行时间（秒）

(with-sandbox (*sandbox*)
  (file-read "/tmp/safe-file.txt"))
```

## 弹性模式

### 重试

```lisp
;; 基本重试
(with-retry (:attempts 3)
  (http-get url))

;; 指数退避
(with-retry (:attempts 5
             :backoff :exponential
             :initial-delay 1000
             :max-delay 30000)
  (external-api-call))

;; 自定义重试条件
(with-retry (:attempts 3
             :retry-on '(connection-error timeout-error)
             :on-retry (lambda (attempt error)
                         (format t "重试 #~A: ~A~%" attempt error)))
  (flaky-operation))
```

### 超时

```lisp
;; 基本超时
(with-timeout (30)
  (long-running-operation))

;; 带回调
(with-timeout (30
               :on-timeout (lambda ()
                             (log-warning "操作超时")
                             :default-value))
  (long-running-operation))
```

### 熔断器

```lisp
;; 创建熔断器
(defvar *circuit-breaker*
  (make-circuit-breaker
    :failure-threshold 5        ; 失败阈值
    :success-threshold 3        ; 恢复阈值
    :timeout 60                 ; 熔断持续时间（秒）
    :on-open (lambda () (log-error "熔断器开启"))
    :on-close (lambda () (log-info "熔断器关闭"))))

;; 使用熔断器
(with-circuit-breaker (*circuit-breaker*)
  (external-service-call))

;; 检查状态
(circuit-breaker-state *circuit-breaker*)  ; => :closed / :open / :half-open
```

### 舱壁隔离

```lisp
;; 限制并发
(defvar *bulkhead*
  (make-bulkhead
    :max-concurrent 10
    :max-waiting 100))

(with-bulkhead (*bulkhead*)
  (concurrent-operation))
```

## 创建自定义插件

```lisp
;; 定义工具
(deftool my-tool "我的自定义工具"
  ((param1 :string "参数1" :required-p t)
   (param2 :int "参数2" :default 0))
  ;; 工具实现
  (format nil "处理: ~A, ~A" param1 param2))

(deftool another-tool "另一个工具"
  ((input :string "输入"))
  (string-upcase input))

;; 创建插件
(defplugin my-custom-plugin "我的自定义插件"
  my-tool
  another-tool)

;; 应用安全策略
(apply-security-policy 'my-custom-plugin
  (make-security-policy
    :rate-limit 30
    :timeout 10))

;; 在 Kernel 中使用
(make-kernel
  :service *service*
  :plugins '(my-custom-plugin file-plugin))
```

## 工具装饰器

为现有工具添加功能：

```lisp
;; 添加日志
(defun with-logging (tool-fn)
  (lambda (&rest args)
    (format t "调用工具，参数: ~A~%" args)
    (let ((result (apply tool-fn args)))
      (format t "结果: ~A~%" result)
      result)))

;; 添加缓存
(defun with-cache (tool-fn &key (ttl 300))
  (let ((cache (make-hash-table :test 'equal)))
    (lambda (&rest args)
      (let ((key (format nil "~A" args)))
        (or (gethash key cache)
            (setf (gethash key cache)
                  (apply tool-fn args)))))))

;; 应用装饰器
(decorate-tool 'http-get
  (with-logging)
  (with-cache :ttl 60)
  (with-retry :attempts 3))
```

## 使用示例

### 安全的文件处理

```lisp
(defvar *file-policy*
  (make-security-policy
    :sandbox-enabled t
    :input-validation-fn
    (lambda (path)
      (and (stringp path)
           (uiop:subpathp path #p"/allowed/directory/")))))

(apply-security-policy 'file-plugin *file-policy*)

;; 现在文件操作受限于 /allowed/directory/
(file-read "/allowed/directory/data.txt")  ; OK
(file-read "/etc/passwd")                   ; 错误：路径不允许
```

### 弹性 HTTP 调用

```lisp
(defvar *api-circuit-breaker*
  (make-circuit-breaker :failure-threshold 3))

(defun call-external-api (endpoint)
  (with-circuit-breaker (*api-circuit-breaker*)
    (with-retry (:attempts 3 :backoff :exponential)
      (with-timeout (30)
        (http-get endpoint)))))
```

### 组合多个插件

```lisp
(defvar *kernel*
  (make-kernel
    :service *service*
    :plugins '(file-plugin
               http-plugin
               utility-plugin
               my-custom-plugin)))

;; Agent 现在可以使用所有插件的工具
(agent-chat *agent* "读取 /tmp/data.txt 并发送到 API")
```
