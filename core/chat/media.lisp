;;;; media.lisp
;;;; CL-Agent Chat - 多模态输入载体（Media）
;;;;
;;;; 概述（对标 Spring AI org.springframework.ai.model.Media
;;;;      与 ai-sdk 的 file/image part）：
;;;;   多模态输入的中立表示。用户消息除文本外可附带若干 media：
;;;;   图片、音频、文档（PDF 等）。
;;;;
;;;;   内容来源二选一：
;;;;     URL  - 远程地址，由厂商自己去取（也可以是 data: URI）
;;;;     DATA - 本地字节 / 已 base64 编码的字符串，随请求体一起上传
;;;;
;;;; 边界纪律（与消息体系一致）：
;;;;   CLOS media 不跨越 provider SPI 边界——message->neutral 时经
;;;;   media->neutral 降为中立 plist：
;;;;     (:kind :image :media-type "image/png" :data "<base64>" :url NIL :name NIL)
;;;;   provider 侧只读这个 plist，并用 media-neutral-data-uri /
;;;;   media-neutral-base64 取内容，不必知道 CLOS 类的存在。
;;;;   base64 编码只有这一份实现。
;;;;
;;;; 使用示例：
;;;;   (user-message "这张图里有什么？"
;;;;                 :media (image-media :url "https://example.com/cat.png"))
;;;;
;;;;   (user-message "总结这份 PDF"
;;;;                 :media (media-from-file #p"/tmp/report.pdf"))
;;;;
;;;;   (user-message "看图说话"
;;;;                 :media (list (image-media :path #p"/tmp/a.png")
;;;;                              (image-media :path #p"/tmp/b.jpg")))

(in-package #:cl-agent/core)

;;; ============================================================
;;; MIME 推断
;;; ============================================================

(defparameter +media-type-by-extension+
  '(("png"  . "image/png")
    ("jpg"  . "image/jpeg")
    ("jpeg" . "image/jpeg")
    ("gif"  . "image/gif")
    ("webp" . "image/webp")
    ("bmp"  . "image/bmp")
    ("svg"  . "image/svg+xml")
    ("pdf"  . "application/pdf")
    ("txt"  . "text/plain")
    ("md"   . "text/markdown")
    ("csv"  . "text/csv")
    ("json" . "application/json")
    ("wav"  . "audio/wav")
    ("mp3"  . "audio/mpeg")
    ("m4a"  . "audio/mp4")
    ("ogg"  . "audio/ogg")
    ("flac" . "audio/flac")
    ("mp4"  . "video/mp4")
    ("webm" . "video/webm"))
  "文件扩展名 → MIME 类型。覆盖各厂商多模态接口实际接受的格式。")

(defun guess-media-type (path)
  "由文件扩展名推断 MIME 类型；未知扩展名返回 application/octet-stream"
  (let* ((type (pathname-type (pathname path)))
         (hit (when type
                (assoc (string-downcase type) +media-type-by-extension+
                       :test #'string=))))
    (if hit (cdr hit) "application/octet-stream")))

(defun media-kind-from-type (media-type)
  "由 MIME 类型推断媒体种类：:image / :audio / :video / :document"
  (cond
    ((null media-type) :document)
    ((eql 0 (search "image/" media-type)) :image)
    ((eql 0 (search "audio/" media-type)) :audio)
    ((eql 0 (search "video/" media-type)) :video)
    (t :document)))

(defun media-format-from-type (media-type)
  "取 MIME 的子类型作为「格式」（OpenAI input_audio 要 \"wav\"/\"mp3\"）。

audio/mpeg 是 mp3 的正式 MIME，但 OpenAI 只认 \"mp3\"，这里做映射。"
  (when media-type
    (let* ((slash (position #\/ media-type))
           (subtype (if slash (subseq media-type (1+ slash)) media-type)))
      (cond
        ((string= subtype "mpeg") "mp3")
        ((string= subtype "x-wav") "wav")
        ((string= subtype "mp4") "m4a")
        (t subtype)))))

(defun read-file-octets (path)
  "读入文件全部字节"
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence bytes in)
      bytes)))

;;; ============================================================
;;; media 值对象
;;; ============================================================

(defclass media ()
  ((kind
    :initarg :kind
    :initform :image
    :reader media-kind
    :documentation "媒体种类关键字：:image / :audio / :video / :document")
   (content-type
    :initarg :media-type
    :initform nil
    :reader media-content-type
    :documentation "MIME 类型（如 \"image/png\"）")
   (data
    :initarg :data
    :initform nil
    :reader media-data
    :documentation "内容字节向量，或已 base64 编码的字符串（与 URL 二选一）")
   (url
    :initarg :url
    :initform nil
    :reader media-url
    :documentation "内容 URL（与 DATA 二选一；也可以是 data: URI）")
   (name
    :initarg :name
    :initform nil
    :reader media-name
    :documentation "文件名（部分厂商的文档上传要求，如 OpenAI 的 file.filename）"))
  (:documentation "多模态输入的一段内容（对标 Spring AI Media）"))

(defun mediap (obj)
  "是否为 media 实例"
  (typep obj 'media))

(definvariants media (self)
  (require-member self 'kind '(:image :audio :video :document)
                  "各 provider 的 wire 转换按它分派")
  ;; data 与 url 二选一：两个都空的 media 会被转成一个没有内容的分片发出去，
  ;; 厂商侧报一个与真实原因无关的 400。
  (require-that self (or (media-data self) (media-url self))
                "data 与 url 必须给一个——两者都空的媒体分片没有内容可发送"))

(defmethod print-object ((m media) stream)
  (print-unreadable-object (m stream :type t)
    (format stream "~A ~@[~A ~]~A"
            (media-kind m)
            (media-content-type m)
            (cond ((media-url m) (media-url m))
                  ((media-data m) (format nil "<~A bytes>"
                                          (length (media-data m))))
                  (t "<empty>")))))

;;; ============================================================
;;; 构造函数
;;; ============================================================

(defun make-media (&key kind media-type data url name path)
  "创建 media。

参数：
  KIND       - :image / :audio / :video / :document（缺省由 MEDIA-TYPE 推断）
  MEDIA-TYPE - MIME 类型（缺省由 PATH 扩展名推断）
  DATA       - 字节向量或 base64 字符串
  URL        - 远程地址或 data: URI
  NAME       - 文件名（缺省取 PATH 的文件名）
  PATH       - 本地文件；给出时读入其字节作为 DATA

DATA / URL / PATH 三者必须给出一个。"
  (when path
    (setf data (or data (read-file-octets path))
          media-type (or media-type (guess-media-type path))
          name (or name (file-namestring (pathname path)))))
  (unless (or data url)
    (signal-error 'validation-error
                  :message "media 需要 :data、:url 或 :path 之一"
                  :field "media"))
  (make-instance 'media
                 :kind (or kind (media-kind-from-type media-type))
                 :media-type media-type
                 :data data
                 :url url
                 :name name))

(defun image-media (&key url data path media-type name)
  "创建图片 media。URL / DATA / PATH 三者给其一。"
  (make-media :kind :image :url url :data data :path path
              :media-type media-type :name name))

(defun audio-media (&key url data path media-type name)
  "创建音频 media。URL / DATA / PATH 三者给其一。"
  (make-media :kind :audio :url url :data data :path path
              :media-type media-type :name name))

(defun document-media (&key url data path media-type name)
  "创建文档 media（PDF / 纯文本等）。URL / DATA / PATH 三者给其一。"
  (make-media :kind :document :url url :data data :path path
              :media-type media-type :name name))

(defun media-from-file (path &key kind media-type name)
  "从本地文件创建 media，MIME 与种类由扩展名推断。"
  (make-media :path path :kind kind :media-type media-type :name name))

;;; ============================================================
;;; 中立 plist 互转（provider SPI 边界）
;;; ============================================================

(defun media->neutral (media)
  "把 media 降为中立 plist（provider 侧读这个）"
  (list :kind (media-kind media)
        :media-type (media-content-type media)
        :data (media-data media)
        :url (media-url media)
        :name (media-name media)))

(defun neutral->media (plist)
  "把中立 media plist 还原为 media 实例"
  (make-instance 'media
                 :kind (or (getf plist :kind) :image)
                 :media-type (getf plist :media-type)
                 :data (getf plist :data)
                 :url (getf plist :url)
                 :name (getf plist :name)))

(defun media-list->neutral (media)
  "把 media（单个或列表）统一降为中立 plist 列表；NIL 原样返回。"
  (let ((items (cond ((null media) nil)
                     ((listp media) media)
                     (t (list media)))))
    (mapcar (lambda (m) (if (mediap m) (media->neutral m) m)) items)))

;;; ============================================================
;;; 内容编码（唯一实现，provider 侧直接调用）
;;; ============================================================

(defun media-neutral-base64 (media-plist)
  "取中立 media plist 的 base64 内容；只有 URL 没有 DATA 时返回 NIL。

DATA 已是字符串时视为「调用方给的就是 base64」，原样返回——
重新编码会把 base64 文本再编一遍，得到一段厂商解不开的垃圾。"
  (let ((data (getf media-plist :data)))
    (cond
      ((null data) nil)
      ((stringp data) data)
      ((vectorp data)
       (cl-base64:usb8-array-to-base64-string
        (coerce data '(vector (unsigned-byte 8)))))
      (t nil))))

(defun media-neutral-data-uri (media-plist)
  "取中立 media plist 的可直接下发的 URI。

有 URL 用 URL（远程地址或调用方自备的 data: URI）；
否则由 DATA + MIME 拼成 data: URI。两者皆无返回 NIL。"
  (or (getf media-plist :url)
      (let ((b64 (media-neutral-base64 media-plist)))
        (when b64
          (format nil "data:~A;base64,~A"
                  (or (getf media-plist :media-type) "application/octet-stream")
                  b64)))))

(defun media-data-uri (media)
  "media 实例的 data URI（CLOS 侧便捷入口，实现同 media-neutral-data-uri）"
  (media-neutral-data-uri (media->neutral media)))
