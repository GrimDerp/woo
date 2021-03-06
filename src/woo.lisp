(in-package :cl-user)
(defpackage woo
  (:nicknames :clack.handler.woo)
  (:use :cl
        :woo.specials
        :woo.signal)
  (:import-from :woo.response
                :*empty-chunk*
                :write-socket-string
                :write-socket-crlf
                :response-headers-bytes
                :write-response-headers
                :write-body-chunk
                :finish-response)
  (:import-from :woo.ev
                :*buffer-size*
                :*connection-timeout*
                :*evloop*
                :socket-remote-addr
                :socket-remote-port)
  (:import-from :quri
                :uri
                :uri-path
                :uri-query
                :uri-error)
  (:import-from :fast-http
                :make-http-request
                :make-parser
                :http-method
                :http-resource
                :http-headers
                :http-major-version
                :http-minor-version
                :parsing-error
                :fast-http-error)
  (:import-from :smart-buffer
                :make-smart-buffer
                :write-to-buffer
                :finalize-buffer)
  (:import-from :trivial-utf-8
                :string-to-utf-8-bytes
                :utf-8-bytes-to-string
                :utf-8-byte-length)
  (:import-from :alexandria
                :hash-table-plist
                :copy-stream
                :if-let)
  (:export :run
           :stop
           :*buffer-size*
           :*connection-timeout*
           :*default-backlog-size*
           :*default-worker-num*))
(in-package :woo)

(defvar *default-backlog-size* 128)
(defvar *default-worker-num* nil)

(defun run (app &key (debug t)
                  (port 5000) (address "0.0.0.0")
                  listen ;; UNIX domain socket
                  (backlog *default-backlog-size*) fd
                  (worker-num *default-worker-num*))
  (assert (and (integerp backlog)
               (plusp backlog)
               (<= backlog 128)))
  (assert (or (and (integerp worker-num)
                   (< 0 worker-num))
              (null worker-num)))
  (when (stringp listen)
    (setf listen (pathname listen)))
  (check-type listen (or pathname null))

  (let ((*app* app)
        (*debug* debug)
        (*listener* nil))
    (labels ((start-socket (socket)
               (setup-parser socket)
               (woo.ev.tcp:start-listening-socket socket))
             (start-multithread-server ()
               (unless (getf vom::*config* :woo.signal)
                 (vom:config :woo.signal :info))
               (let ((*cluster* (woo.worker:make-cluster worker-num #'start-socket))
                     (signal-watchers (make-signal-watchers)))
                 (unwind-protect
                      (wev:with-event-loop (:cleanup-fn
                                            (lambda ()
                                              (stop-signal-watchers *evloop* signal-watchers)))
                        (start-signal-watchers *evloop* signal-watchers)
                        (setq *listener*
                              (wev:tcp-server (or listen
                                                  (cons address port))
                                              #'read-cb
                                              :connect-cb
                                              (lambda (socket)
                                                (woo.worker:add-job-to-cluster *cluster* socket))
                                              :backlog backlog
                                              :fd fd
                                              :sockopt wsock:+SO-REUSEADDR+)))
                   (wev:close-tcp-server *listener*)
                   (woo.worker:stop-cluster *cluster*))))
             (start-singlethread-server ()
               (let ((signal-watchers (make-signal-watchers)))
                 (unwind-protect
                      (wev:with-event-loop (:cleanup-fn
                                            (lambda ()
                                              (stop-signal-watchers *evloop* signal-watchers)))
                        (start-signal-watchers *evloop* signal-watchers)
                        (setq *listener*
                              (wev:tcp-server (or listen
                                                  (cons address port))
                                              #'read-cb
                                              :connect-cb #'start-socket
                                              :backlog backlog
                                              :fd fd
                                              :sockopt wsock:+SO-REUSEADDR+)))
                   (wev:close-tcp-server *listener*)))))
      (if worker-num
          (start-multithread-server)
          (start-singlethread-server)))))

(defun read-cb (socket data &key (start 0) (end (length data)))
  (let ((parser (wev:socket-data socket)))
    (handler-case (funcall parser data :start start :end end)
      (fast-http:parsing-error (e)
        (vom:error "HTTP parse error: ~A" e)
        (let ((body #.(map '(simple-array (unsigned-byte 8) (*))
                           #'char-code
                           "400 Bad Request")))
          (wev:with-async-writing (socket :write-cb #'wev:close-socket)
            (write-response-headers socket 400
                                    (list :connection "close"
                                          :content-length (length body)))
            (wev:write-socket-data socket body)))))))

(define-condition woo-error (simple-error) ())
(define-condition invalid-http-version (woo-error) ())

(defun http-version-keyword (major minor)
  (unless (= major 1)
    (error 'invalid-http-version))

  (case minor
    (1 :HTTP/1.1)
    (0 :HTTP/1.0)
    (otherwise (error 'invalid-http-version))))

(define-condition bad-request (condition) ())

(defun setup-parser (socket)
  (let ((http (make-http-request))
        (body-buffer (make-smart-buffer)))
    (setf (wev:socket-data socket)
          (make-parser http
                       :body-callback
                       (lambda (data start end)
                         (declare (type (simple-array (unsigned-byte 8) (*)) data))
                         (write-to-buffer body-buffer data start end))
                       :finish-callback
                       (lambda ()
                         (handler-case
                             (let ((raw-body (finalize-buffer body-buffer)))
                               (setq body-buffer (make-smart-buffer))
                               (let ((env (nconc (list :raw-body raw-body)
                                                 (handle-request http socket))))
                                 (handle-response http socket
                                                  (if *debug*
                                                      (funcall *app* env)
                                                      (if-let (res (handler-case (funcall *app* env)
                                                                     (error (error)
                                                                       (vom:error (princ-to-string error))
                                                                       nil)))
                                                        res
                                                        '(500 nil nil))))))
                           (bad-request ()
                             (let ((body "400 Bad Request"))
                               (handle-response http socket
                                                `(400
                                                  (:connection "close"
                                                   :content-length ,(length body))
                                                  (,body)))))))))))

(defun stop (server)
  (wev:close-tcp-server server))


;;
;; Handling requests

(defun parse-host-header (host)
  (declare (type simple-string host)
           (optimize (speed 3) (safety 0)))
  (let ((pos (position #\: host :from-end t)))
    (unless pos
      (return-from parse-host-header
        (values host nil)))

    (locally (declare (type fixnum pos))
      (let ((port (loop with port = 0
                        for i from (1+ pos) to (1- (length host))
                        for char = (aref host i)
                        do (if (digit-char-p char)
                               (setq port (+ (* 10 port)
                                             (- (char-code char) (char-code #\0))))
                               (return nil))
                        finally
                           (return port))))
        (if port
            (values (subseq host 0 pos)
                    port)
            (values host nil))))))

(defun handle-request (http socket)
  (handler-case
      (let ((host (gethash "host" (http-headers http)))
            (headers (http-headers http))
            (uri (http-resource http)))
        (declare (type simple-string uri))

        (multiple-value-bind (scheme userinfo hostname port path query fragment)
            (quri:parse-uri uri)
          (declare (ignore scheme userinfo hostname port fragment))
          (multiple-value-bind (server-name server-port)
              (if (stringp host)
                  (parse-host-header host)
                  (values nil nil))
            (list :request-method (http-method http)
                  :script-name ""
                  :server-name server-name
                  :server-port (or server-port 80)
                  :server-protocol (http-version-keyword (http-major-version http) (http-minor-version http))
                  :path-info (and path
                                  (handler-case (quri:url-decode path)
                                    (quri:uri-error ()
                                      path)))
                  :query-string query
                  :url-scheme :http
                  :remote-addr (socket-remote-addr socket)
                  :remote-port (socket-remote-port socket)
                  :request-uri uri
                  :clack.streaming t
                  :clack.nonblocking t
                  :clack.io socket
                  :content-length (gethash "content-length" headers)
                  :content-type (gethash "content-type" headers)
                  :headers headers))))
    (error ()
      (signal 'bad-request))))


;;
;; Handling responses

(defun handle-response (http socket clack-res)
  (handler-case
      (etypecase clack-res
        (list (handle-normal-response http socket clack-res))
        (function (funcall clack-res (lambda (clack-res)
                                       (handler-case
                                           (handle-normal-response http socket clack-res)
                                         (wev:socket-closed ()))))))
    (wev:tcp-error (e)
      (vom:error (princ-to-string e)))))

#+sbcl
(defvar *stat* (make-instance 'sb-posix:stat))
#+sbcl
(defun fd-file-size (fd)
  (sb-posix:fstat fd *stat*)
  (sb-posix:stat-size *stat*))
#+ccl
(defun fd-file-size (fd)
  (multiple-value-bind (successp mode size)
      (ccl::%fstat fd)
    (declare (ignore mode))
    (unless successp
      (error "'fstat' failed"))
    size))
#-(or sbcl ccl)
(defun file-size (path)
  (with-open-file (in path)
    (file-length in)))

(defun handle-normal-response (http socket clack-res)
  (let ((no-body '#:no-body)
        (close (or (= (http-minor-version http) 0)
                   (string-equal (gethash "connection" (http-headers http)) "close"))))
    (destructuring-bind (status headers &optional (body no-body))
        clack-res
      (when (eq body no-body)
        (setf (getf headers :transfer-encoding) "chunked")
        (setf (getf headers :content-length) nil)
        (wev:with-async-writing (socket)
          (write-response-headers socket status headers))
        (return-from handle-normal-response
          (lambda (body &key (close nil))
            (wev:with-async-writing (socket)
              (etypecase body
                (string (write-body-chunk socket (trivial-utf-8:string-to-utf-8-bytes body)))
                (vector (write-body-chunk socket body)))
              (when close
                (finish-response socket *empty-chunk*))))))

      (etypecase body
        (null
         (wev:with-async-writing (socket :write-cb (and close
                                                        (lambda (socket)
                                                          (wev:close-socket socket))))
           (unless (= status 304)
             (setf (getf headers :content-length) 0))
           (write-response-headers socket status headers (not close))))
        (pathname
         (let* ((fd (wsys:open body))
                (size #+(or sbcl ccl) (fd-file-size fd)
                      #-(or sbcl ccl) (file-size body)))
           (unless (getf headers :content-length)
             (setf (getf headers :content-length) size))
           (wev:with-async-writing (socket :write-cb (and close
                                                          (lambda (socket)
                                                            (wev:close-socket socket))))
             (write-response-headers socket status headers (not close))
             (woo.ev.socket:send-static-file socket fd size))))
        (list
         (wev:with-async-writing (socket :write-cb (and close
                                                        (lambda (socket)
                                                          (wev:close-socket socket))))
           (cond
             ((getf headers :content-length)
              (response-headers-bytes socket status headers (not close))
              (write-socket-crlf socket)
              (loop for str in body
                    do (wev:write-socket-data socket (string-to-utf-8-bytes str))))
             (T
              (cond
                ((= (http-minor-version http) 1)
                 ;; Transfer-Encoding: chunked
                 (response-headers-bytes socket status headers (not close))
                 (wev:write-socket-data socket #.(string-to-utf-8-bytes "Transfer-Encoding: chunked"))
                 (write-socket-crlf socket)
                 (write-socket-crlf socket)
                 (loop for str in body
                       for data = (string-to-utf-8-bytes str)
                       do (write-socket-string socket (the simple-string (format nil "~X" (length data))))
                          (write-socket-crlf socket)
                          (wev:write-socket-data socket data)
                          (write-socket-crlf socket))
                 (wev:write-socket-byte socket #.(char-code #\0))
                 (write-socket-crlf socket)
                 (write-socket-crlf socket))
                (T
                 ;; calculate Content-Length
                 (response-headers-bytes socket status headers (not close))
                 (wev:write-socket-data socket #.(string-to-utf-8-bytes "Content-Length: "))
                 (write-socket-string
                  socket
                  (write-to-string (loop for str in body
                                         sum (utf-8-byte-length str))))
                 (write-socket-crlf socket)
                 (write-socket-crlf socket)
                 (loop for str in body
                       do (wev:write-socket-data socket (string-to-utf-8-bytes str)))))))))
        ((vector (unsigned-byte 8))
         (wev:with-async-writing (socket :write-cb (and close
                                                        (lambda (socket)
                                                          (wev:close-socket socket))))
           (response-headers-bytes socket status headers (not close))
           (unless (getf headers :content-length)
             (wev:write-socket-data socket #.(string-to-utf-8-bytes "Content-Length: "))
             (write-socket-string socket (write-to-string (length body)))
             (write-socket-crlf socket))
           (write-socket-crlf socket)
           (wev:write-socket-data socket body)))))))

(defmethod clack.socket:set-read-callback ((socket woo.ev.socket:socket) callback)
  (setf (wev:socket-data socket) callback))

(defmethod clack.socket:write-sequence-to-socket ((socket woo.ev.socket:socket) data &key callback)
  (wev:with-async-writing (socket :write-cb (and callback
                                                 (lambda (socket)
                                                   (declare (ignore socket))
                                                   (funcall callback))))
    (wev:write-socket-data socket data)))

(defmethod clack.socket:write-byte-to-socket ((socket woo.ev.socket:socket) byte &key callback)
  (wev:with-async-writing (socket :write-cb (and callback
                                                 (lambda (socket)
                                                   (declare (ignore socket))
                                                   (funcall callback))))
    (wev:write-socket-byte socket byte)))

(defmethod clack.socket:write-sequence-to-socket-buffer ((socket woo.ev.socket:socket) data)
  (wev:write-socket-data socket data))

(defmethod clack.socket:write-byte-to-socket-buffer ((socket woo.ev.socket:socket) byte)
  (wev:write-socket-byte socket byte))

(defmethod clack.socket:flush-socket-buffer ((socket woo.ev.socket:socket) &key callback)
  (wev:with-async-writing (socket :write-cb (and callback
                                                 (lambda (socket)
                                                   (declare (ignore socket))
                                                   (funcall callback))))
    nil))

(defmethod clack.socket:close-socket ((socket woo.ev.socket:socket))
  (when (woo.ev.socket:socket-open-p socket)
    (woo.ev.socket:close-socket socket)))
