;;;; test-media.lisp
;;;; CL-Agent - 多模态输入测试
;;;;
;;;; 覆盖：
;;;;   - media 值对象：构造 / MIME 推断 / base64 与 data URI 编码
;;;;   - user-message 携带 media + 中立 plist 往返
;;;;   - OpenAI 兼容 wire：content 分片数组（image_url / input_audio / file）
;;;;   - Anthropic wire：content 块数组（image / document，base64 与 url 两种 source）

(in-package :cl-agent/tests)

(def-suite media-suite :in cl-agent-suite
  :description "多模态输入：media 值对象 + 两套 wire 转换")

(in-suite media-suite)

;;; ============================================================
;;; media 值对象
;;; ============================================================

(test media-type-guessed-from-extension
  "MIME 由扩展名推断，未知扩展名退化为 octet-stream"
  (is (string= "image/png" (cl-agent.core:guess-media-type "/tmp/a.png")))
  (is (string= "image/jpeg" (cl-agent.core:guess-media-type "/tmp/a.JPG")))
  (is (string= "application/pdf" (cl-agent.core:guess-media-type "/tmp/r.pdf")))
  (is (string= "audio/mpeg" (cl-agent.core:guess-media-type "/tmp/s.mp3")))
  (is (string= "application/octet-stream"
               (cl-agent.core:guess-media-type "/tmp/x.unknown"))))

(test media-kind-inferred-from-mime
  "种类由 MIME 前缀推断"
  (is (eq :image (cl-agent.core:media-kind-from-type "image/png")))
  (is (eq :audio (cl-agent.core:media-kind-from-type "audio/wav")))
  (is (eq :video (cl-agent.core:media-kind-from-type "video/mp4")))
  (is (eq :document (cl-agent.core:media-kind-from-type "application/pdf")))
  ;; MIME 缺失时按文档处理
  (is (eq :document (cl-agent.core:media-kind-from-type nil))))

(test media-format-maps-mpeg-to-mp3
  "OpenAI 的 input_audio.format 只认 mp3/wav，audio/mpeg 需映射"
  (is (string= "mp3" (cl-agent.core:media-format-from-type "audio/mpeg")))
  (is (string= "wav" (cl-agent.core:media-format-from-type "audio/wav")))
  (is (string= "m4a" (cl-agent.core:media-format-from-type "audio/mp4"))))

(test media-requires-content
  "既无 data 也无 url 时报 validation-error"
  (signals cl-agent.core:validation-error
    (cl-agent.core:make-media :kind :image)))

(test media-url-constructor
  "URL 形态：data URI 即 URL 本身"
  (let ((m (cl-agent.core:image-media :url "https://example.com/cat.png")))
    (is (eq :image (cl-agent.core:media-kind m)))
    (is (string= "https://example.com/cat.png" (cl-agent.core:media-url m)))
    (is (string= "https://example.com/cat.png"
                 (cl-agent.core:media-data-uri m)))))

(test media-bytes-encoded-to-data-uri
  "字节形态：编码为 data URI"
  (let* ((bytes (make-array 3 :element-type '(unsigned-byte 8)
                              :initial-contents '(1 2 3)))
         (m (cl-agent.core:image-media :data bytes :media-type "image/png"))
         (uri (cl-agent.core:media-data-uri m)))
    (is (eql 0 (search "data:image/png;base64," uri)))
    ;; base64 内容可解回原字节
    (is (equalp bytes
                (cl-base64:base64-string-to-usb8-array
                 (subseq uri (length "data:image/png;base64,")))))))

(test media-string-data-treated-as-base64
  "data 已是字符串时视为 base64，不再二次编码"
  (let ((m (cl-agent.core:image-media :data "QUJD" :media-type "image/png")))
    (is (string= "QUJD" (cl-agent.core:media-neutral-base64
                         (cl-agent.core:media->neutral m))))
    (is (string= "data:image/png;base64,QUJD" (cl-agent.core:media-data-uri m)))))

(test media-from-file-reads-bytes-and-mime
  "media-from-file 读入字节并推断 MIME / 文件名"
  (let ((path (merge-pathnames "cl-agent-media-test.png"
                               (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output
                                     :element-type '(unsigned-byte 8)
                                     :if-exists :supersede)
             (write-sequence (make-array 4 :element-type '(unsigned-byte 8)
                                           :initial-contents '(10 20 30 40))
                             out))
           (let ((m (cl-agent.core:media-from-file path)))
             (is (eq :image (cl-agent.core:media-kind m)))
             (is (string= "image/png" (cl-agent.core:media-content-type m)))
             (is (string= "cl-agent-media-test.png" (cl-agent.core:media-name m)))
             (is (= 4 (length (cl-agent.core:media-data m))))))
      (ignore-errors (delete-file path)))))

;;; ============================================================
;;; 消息携带 media + 中立互转
;;; ============================================================

(test user-message-carries-media
  "user-message 接受单个 media 或列表，统一存为列表"
  (let ((one (cl-agent.core:user-message
              "看图" :media (cl-agent.core:image-media :url "u1")))
        (two (cl-agent.core:user-message
              "看图" :media (list (cl-agent.core:image-media :url "u1")
                                  (cl-agent.core:image-media :url "u2")))))
    (is (= 1 (length (cl-agent.core:message-media one))))
    (is (= 2 (length (cl-agent.core:message-media two))))))

(test message-media-defaults-to-nil
  "非 user 消息的 message-media 恒为 NIL（调用方无需判类型）"
  (is (null (cl-agent.core:message-media (cl-agent.core:system-message "s"))))
  (is (null (cl-agent.core:message-media (cl-agent.core:assistant-message "a"))))
  (is (null (cl-agent.core:message-media (cl-agent.core:user-message "u")))))

(test message->neutral-carries-media
  "message->neutral 把 media 降为中立 plist"
  (let* ((msg (cl-agent.core:user-message
               "这是什么"
               :media (cl-agent.core:image-media :url "https://x/y.png"
                                                 :media-type "image/png")))
         (neutral (first (cl-agent.core:message->neutral msg)))
         (media (first (getf neutral :media))))
    (is (equal "这是什么" (getf neutral :content)))
    ;; 中立层是 plist，不是 CLOS 实例（SPI 边界纪律）
    (is (listp media))
    (is (eq :image (getf media :kind)))
    (is (string= "image/png" (getf media :media-type)))
    (is (string= "https://x/y.png" (getf media :url)))))

(test message->neutral-omits-media-key-when-absent
  "没有附件时不出现 :media 键"
  (let ((neutral (first (cl-agent.core:message->neutral
                         (cl-agent.core:user-message "纯文本")))))
    (is (null (getf neutral :media)))))

(test neutral->message-roundtrips-media
  "中立 plist → CLOS 消息，media 不丢"
  (let* ((original (cl-agent.core:user-message
                    "看图"
                    :media (cl-agent.core:image-media :url "u" :media-type "image/png")))
         (neutral (first (cl-agent.core:message->neutral original)))
         (restored (cl-agent.core:neutral->message neutral))
         (media (first (cl-agent.core:message-media restored))))
    (is (cl-agent.core:mediap media))
    (is (eq :image (cl-agent.core:media-kind media)))
    (is (string= "u" (cl-agent.core:media-url media)))))

;;; ============================================================
;;; OpenAI 兼容 wire
;;; ============================================================

(defun openai-wire-message (msg)
  "取单条中立消息的 OpenAI wire 形态"
  (elt (cl-agent.llm.providers::convert-messages-for-openai (list msg)) 0))

(test openai-plain-message-content-stays-string
  "无附件的消息 content 仍是字符串（不无端升级为数组）"
  (let ((wire (openai-wire-message (list :role :user :content "hi"))))
    (is (string= "hi" (gethash "content" wire)))))

(test openai-image-becomes-image-url-part
  "图片附件 → image_url 分片，文本分片在前"
  (let* ((wire (openai-wire-message
                (list :role :user :content "这是什么"
                      :media (list (list :kind :image
                                         :media-type "image/png"
                                         :url "https://x/y.png")))))
         (parts (gethash "content" wire)))
    (is (vectorp parts))
    (is (= 2 (length parts)))
    (is (string= "text" (gethash "type" (elt parts 0))))
    (is (string= "这是什么" (gethash "text" (elt parts 0))))
    (is (string= "image_url" (gethash "type" (elt parts 1))))
    (is (string= "https://x/y.png"
                 (gethash "url" (gethash "image_url" (elt parts 1)))))))

(test openai-image-bytes-become-data-uri
  "字节图片编码进 data URI"
  (let* ((wire (openai-wire-message
                (list :role :user :content ""
                      :media (list (list :kind :image
                                         :media-type "image/jpeg"
                                         :data "QUJD")))))
         (parts (gethash "content" wire)))
    ;; 文本为空 → 不发文本分片
    (is (= 1 (length parts)))
    (is (string= "data:image/jpeg;base64,QUJD"
                 (gethash "url" (gethash "image_url" (elt parts 0)))))))

(test openai-audio-part-uses-raw-base64
  "音频分片是裸 base64 + format（不是 data URI）"
  (let* ((wire (openai-wire-message
                (list :role :user :content "听"
                      :media (list (list :kind :audio
                                         :media-type "audio/mpeg"
                                         :data "QUJD")))))
         (audio (gethash "input_audio" (elt (gethash "content" wire) 1))))
    (is (string= "input_audio" (gethash "type" (elt (gethash "content" wire) 1))))
    (is (string= "QUJD" (gethash "data" audio)))
    (is (string= "mp3" (gethash "format" audio)))))

(test openai-document-part
  "文档附件 → file 分片，带文件名"
  (let* ((wire (openai-wire-message
                (list :role :user :content "总结"
                      :media (list (list :kind :document
                                         :media-type "application/pdf"
                                         :name "r.pdf"
                                         :data "QUJD")))))
         (file (gethash "file" (elt (gethash "content" wire) 1))))
    (is (string= "r.pdf" (gethash "filename" file)))
    (is (string= "data:application/pdf;base64,QUJD" (gethash "file_data" file)))))

(test openai-untranslatable-media-skipped
  "只有 URL 的音频无法构造分片 —— 跳过它，而不是让整条消息发不出去"
  (let* ((wire (openai-wire-message
                (list :role :user :content "听"
                      :media (list (list :kind :audio :url "https://x/a.mp3")))))
         (parts (gethash "content" wire)))
    (is (= 1 (length parts)))
    (is (string= "text" (gethash "type" (elt parts 0))))))

;;; ============================================================
;;; Anthropic wire
;;; ============================================================

(defun anthropic-wire-message (msg)
  "取单条中立消息的 Anthropic wire 形态"
  (first (getf (cl-agent.llm.providers::parse-messages-for-anthropic (list msg))
               :messages)))

(test anthropic-image-url-source
  "远程图片 → source.type = url"
  (let* ((wire (anthropic-wire-message
                (list :role :user :content "这是什么"
                      :media (list (list :kind :image
                                         :media-type "image/png"
                                         :url "https://x/y.png")))))
         (blocks (gethash "content" wire)))
    (is (vectorp blocks))
    (is (= 2 (length blocks)))
    (is (string= "text" (gethash "type" (elt blocks 0))))
    (is (string= "image" (gethash "type" (elt blocks 1))))
    (let ((source (gethash "source" (elt blocks 1))))
      (is (string= "url" (gethash "type" source)))
      (is (string= "https://x/y.png" (gethash "url" source))))))

(test anthropic-image-base64-source
  "字节图片 → source.type = base64 + media_type"
  (let* ((wire (anthropic-wire-message
                (list :role :user :content "看"
                      :media (list (list :kind :image
                                         :media-type "image/jpeg"
                                         :data "QUJD")))))
         (source (gethash "source" (elt (gethash "content" wire) 1))))
    (is (string= "base64" (gethash "type" source)))
    (is (string= "image/jpeg" (gethash "media_type" source)))
    (is (string= "QUJD" (gethash "data" source)))))

(test anthropic-data-uri-stripped-to-base64
  "调用方给的 data: URI 要剥前缀 —— Anthropic 的 data 字段只收裸 base64"
  (let* ((wire (anthropic-wire-message
                (list :role :user :content "看"
                      :media (list (list :kind :image
                                         :media-type "image/png"
                                         :url "data:image/png;base64,QUJD")))))
         (source (gethash "source" (elt (gethash "content" wire) 1))))
    (is (string= "base64" (gethash "type" source)))
    (is (string= "QUJD" (gethash "data" source)))))

(test anthropic-document-block
  "PDF → document 块"
  (let* ((wire (anthropic-wire-message
                (list :role :user :content "总结"
                      :media (list (list :kind :document
                                         :media-type "application/pdf"
                                         :data "QUJD")))))
         (block-hash (elt (gethash "content" wire) 1)))
    (is (string= "document" (gethash "type" block-hash)))
    (is (string= "application/pdf"
                 (gethash "media_type" (gethash "source" block-hash))))))

(test anthropic-skips-audio
  "Anthropic 不接受音频输入 —— 跳过，不制造必然 400 的请求"
  (let* ((wire (anthropic-wire-message
                (list :role :user :content "听"
                      :media (list (list :kind :audio
                                         :media-type "audio/wav"
                                         :data "QUJD")))))
         (blocks (gethash "content" wire)))
    (is (= 1 (length blocks)))
    (is (string= "text" (gethash "type" (elt blocks 0))))))

(test anthropic-plain-message-content-stays-string
  "无附件的消息 content 仍是字符串"
  (let ((wire (anthropic-wire-message (list :role :user :content "hi"))))
    (is (string= "hi" (gethash "content" wire)))))

;;; ============================================================
;;; DashScope 原生 wire
;;; ============================================================

(defun dashscope-request (msg)
  "取单条中立消息的 DashScope 原生请求体"
  (cl-agent.llm.providers::build-dashscope-request
   (cl-agent.llm.providers:make-dashscope-provider :api-key "k")
   (list msg)
   :model "qwen-vl-max"))

(defun dashscope-wire-message (msg)
  (elt (gethash "messages" (gethash "input" (dashscope-request msg))) 0))

(test dashscope-plain-message-content-stays-string
  "无附件的消息 content 仍是字符串"
  (is (string= "hi" (gethash "content"
                             (dashscope-wire-message
                              (list :role :user :content "hi"))))))

(test dashscope-image-becomes-content-part
  "图片附件 → DashScope 的单键分片 {\"image\": ...}，附件在文本之前"
  (let ((parts (gethash "content"
                        (dashscope-wire-message
                         (list :role :user :content "这是什么"
                               :media (list (list :kind :image
                                                  :media-type "image/png"
                                                  :url "https://x/y.png")))))))
    (is (vectorp parts))
    (is (= 2 (length parts)))
    (is (string= "https://x/y.png" (gethash "image" (elt parts 0))))
    (is (string= "这是什么" (gethash "text" (elt parts 1))))))

(test dashscope-image-bytes-become-data-uri
  "字节图片编码进 data URI（DashScope 接受 data: 形态）"
  (let ((parts (gethash "content"
                        (dashscope-wire-message
                         (list :role :user :content ""
                               :media (list (list :kind :image
                                                  :media-type "image/jpeg"
                                                  :data "QUJD")))))))
    (is (= 1 (length parts)))
    (is (string= "data:image/jpeg;base64,QUJD" (gethash "image" (elt parts 0))))))

(test dashscope-audio-part
  "音频 → {\"audio\": ...} 分片"
  (let ((parts (gethash "content"
                        (dashscope-wire-message
                         (list :role :user :content "听"
                               :media (list (list :kind :audio
                                                  :media-type "audio/wav"
                                                  :url "https://x/a.wav")))))))
    (is (string= "https://x/a.wav" (gethash "audio" (elt parts 0))))))

(test dashscope-document-skipped
  "PDF 不属于多模态 generation 端点 —— 跳过而不是发必然 400 的请求"
  (let ((parts (gethash "content"
                        (dashscope-wire-message
                         (list :role :user :content "总结"
                               :media (list (list :kind :document
                                                  :media-type "application/pdf"
                                                  :data "QUJD")))))))
    (is (= 1 (length parts)))
    (is (string= "总结" (gethash "text" (elt parts 0))))))

(test dashscope-multimodal-omits-result-format
  "多模态端点不接受 result_format 参数"
  (let ((with-media (dashscope-request
                     (list :role :user :content "看"
                           :media (list (list :kind :image :url "https://x/y.png")))))
        (text-only (dashscope-request (list :role :user :content "hi"))))
    (is-false (nth-value 1 (gethash "result_format"
                                    (gethash "parameters" with-media))))
    (is (string= "message" (gethash "result_format"
                                    (gethash "parameters" text-only))))))

(test dashscope-media-routes-to-multimodal-endpoint
  "带附件的请求必须走多模态端点（两个端点不通用）"
  (is (cl-agent.llm.providers::messages-have-media-p
       (list (list :role :user :content "看"
                   :media (list (list :kind :image :url "u"))))))
  (is-false (cl-agent.llm.providers::messages-have-media-p
             (list (list :role :user :content "hi"))))
  (is (string= "/api/v1/services/aigc/multimodal-generation/generation"
               cl-agent.llm.providers::+dashscope-multimodal-endpoint+)))

(test dashscope-multimodal-response-content-flattened
  "多模态响应的 content 是分片数组，必须归一为字符串"
  (let ((response (cl-agent.llm.providers::parse-dashscope-response
                   "{\"output\":{\"choices\":[{\"finish_reason\":\"stop\",
                     \"message\":{\"role\":\"assistant\",
                     \"content\":[{\"text\":\"一只猫\"}]}}]},
                     \"usage\":{\"input_tokens\":10,\"output_tokens\":3}}")))
    (is (stringp (cl-agent.core:llm-response-content response)))
    (is (string= "一只猫" (cl-agent.core:llm-response-content response)))))

(test dashscope-text-response-content-unchanged
  "纯文本响应的 content 仍按字符串解析（归一化不能改坏老路径）"
  (let ((response (cl-agent.llm.providers::parse-dashscope-response
                   "{\"output\":{\"choices\":[{\"finish_reason\":\"stop\",
                     \"message\":{\"role\":\"assistant\",\"content\":\"你好\"}}]}}")))
    (is (string= "你好" (cl-agent.core:llm-response-content response)))))

;;; ============================================================
;;; 端到端：ChatModel → SPI
;;; ============================================================

(test media-reaches-provider-spi
  "prompt 里的 media 一路穿过 ChatModel 适配层到达 llm-chat SPI"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent.core:make-provider-chat-model provider)))
    (cl-agent.core:chat-model-call
     model
     (cl-agent.core:make-prompt
      (list (cl-agent.core:user-message
             "这是什么"
             :media (cl-agent.core:image-media :url "https://x/y.png")))))
    (let* ((request (first (seq-provider-requests provider)))
           (msg (first (getf request :messages))))
      (is (string= "https://x/y.png" (getf (first (getf msg :media)) :url))))))
