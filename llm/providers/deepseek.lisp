;;;; deepseek.lisp
;;;; CL-Agent - DeepSeek 提供商实现
;;;;
;;;; 概述（参照 clj-agent provider/deepseek.clj）：
;;;;   DeepSeek —— OpenAI 兼容实现，纯声明式定义 + 前缀续写扩展。
;;;;
;;;; 支持的模型：
;;;;   - deepseek-chat（DeepSeek-V3）
;;;;   - deepseek-reasoner（DeepSeek-R1，思维链经 reasoning_content
;;;;     自动归一化到 llm-response-reasoning，content 为干净答案）
;;;;
;;;; DeepSeek 专属差异：
;;;;   - reasoning_content：openai-compat 基座已统一提取
;;;;   - 前缀续写（beta）：deepseek-prefix-chat / mark-prefix，
;;;;     最后一条 assistant 消息标记 prefix:true，模型从该前缀继续生成
;;;;     （自动走 https://api.deepseek.com/beta 路径），常与 :stop 搭配
;;;;   - deepseek-reasoner 忽略 temperature/top_p/presence_penalty/
;;;;     frequency_penalty —— 本实现「存在才发送」，不传即安全

(in-package :cl-agent/llm/providers)

(define-openai-compat-provider deepseek
  :base-url "https://api.deepseek.com"
  :env-key "DEEPSEEK_API_KEY"
  :default-model "deepseek-chat"
  :documentation "DeepSeek 提供商（OpenAI 兼容端点）

模型：deepseek-chat（V3）、deepseek-reasoner（R1，思维链自动归一化）。
前缀续写见 deepseek-prefix-chat。")

;;; ============================================================
;;; 前缀续写（Chat Prefix Completion，beta）
;;; ============================================================
;;; 文档：base_url 须为 https://api.deepseek.com/beta，
;;; 最后一条消息为 assistant 且 prefix=true，模型从其 content 继续生成。

(defparameter +deepseek-beta-base-url+ "https://api.deepseek.com/beta"
  "DeepSeek beta 功能基础 URL（前缀续写等）")

(defun mark-prefix (messages)
  "把最后一条 assistant 消息标记为前缀（:prefix t）。

参数：
  MESSAGES - 中立消息 plist 列表，最后一条必须是 assistant

返回：
  标记后的消息列表（副本）；最后一条非 assistant 时报错。"
  (let* ((msgs (mapcar #'copy-list messages))
         (last-msg (car (last msgs))))
    (unless (and last-msg (eq (getf last-msg :role) :assistant))
      (error "前缀续写要求最后一条消息为 assistant，实际为 ~S"
             (getf last-msg :role)))
    (setf (getf (car (last msgs)) :prefix) t)
    msgs))

(defun deepseek-prefix-chat (provider messages &rest args
                             &key max-tokens temperature model stop extra-params
                             &allow-other-keys)
  "对话前缀续写（beta）。

最后一条 assistant 消息的 content 作为前缀，模型从其继续生成
（建议搭配 :stop 控制结束位置）。

参数：
  PROVIDER - deepseek provider 实例
  MESSAGES - 中立消息列表，最后一条为 assistant（前缀）
  其余关键字参数与 llm-chat 一致。

返回：
  llm-response 对象（续写内容在 content）

示例：
  (deepseek-prefix-chat provider
    (list (list :role :user :content \"写一句诗\")
          (list :role :assistant :content \"春天的风\"))
    :max-tokens 256)"
  (declare (ignore max-tokens temperature model stop extra-params))
  ;; 克隆 provider，切换到 beta 基础 URL（不改动原实例）
  (let ((beta-provider (make-instance 'deepseek-provider
                                      :name :deepseek
                                      :api-url +deepseek-beta-base-url+
                                      :default-model (cl-agent/llm:base-provider-default-model provider)
                                      :chat-endpoint (cl-agent/llm:base-provider-chat-endpoint provider)
                                      :stream-endpoint (cl-agent/llm:base-provider-stream-endpoint provider)
                                      :api-key (provider-api-key provider)
                                      :timeout (cl-agent/llm:base-provider-timeout provider))))
    (apply #'cl-agent/llm:llm-chat beta-provider (mark-prefix messages) args)))
