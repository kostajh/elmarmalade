;;; marmalade-api.el --- api for elmarmalade  -*- lexical-binding: t -*-

(require 'elnode)
(require 'db)
(require 'marmalade-users)
(require 'noflet)

(defun marmalade-api/user-login (httpcon)
  "Return the user's authentication token.

The token is required by API v1 for authenticating all calls.

HTTP parameters \"NAME\" and \"PASSWORD\" specify the username
and password to be authenticated." 
  (let ((username (elnode-http-param httpcon "name"))
        (password (elnode-http-param httpcon "password"))
        (method (elnode-http-method httpcon)))
    (noflet ((elnode-send-400 (httpcon &optional message)
               (elnode-http-start httpcon 400 '(content-type . "application/json"))
               (elnode-http-return httpcon (json-encode `((message . ,message))))))
      (cond
        ;; List of constraints
        ((not (equal method "POST")) (elnode-send-400 httpcon "only POST supported"))
        ((equal username "") (elnode-send-400 httpcon "no user specified"))
        ((not username) (elnode-send-400 httpcon "no user specified"))
        ((not (stringp username)) (elnode-send-400 httpcon "don't understand non-string username"))
        ((equal password "") (elnode-send-400 httpcon "no password specified"))
        ((not password) (elnode-send-400 httpcon "no password specified"))
        ((not (stringp  password)) (elnode-send-400 httpcon "don't understand non-string password specified"))
        ((let ((user-record (db-get username marmalade/users)))
           (not (equal
                 (kva "digest" user-record)
                 (marmalade/user-hash password (kva "salt" user-record)))))
         (elnode-send-400 httpcon "bad authentication"))
        ;; Success!
        (t (elnode-send-json
            httpcon
            `((token . ,(kva "token" (db-get username marmalade/users))))))))))

(defun marmalade-api/upload (httpcon)
  "Upload a package."
  (let* ((method (elnode-http-method httpcon))
         (username (elnode-http-param httpcon "name"))
         (token (elnode-http-param httpcon "token"))
         (upload-file (elnode-http-param httpcon "package"))
         (upload-file-name
          (condition-case err
             (get-text-property 0 :elnode-filename upload-file)
            (error nil))))
    (noflet ((elnode-send-400 (httpcon &optional message)
               (elnode-http-start httpcon 400 '(content-type . "application/json"))
               (elnode-http-return httpcon (json-encode `((message . ,message))))))
      (cond
        ((not (equal method "POST")) (elnode-send-400 httpcon "only POST supported"))
        ((not token) (elnode-send-400 httpcon "no token specified, use login to get a token"))
        ((not (stringp token)) (elnode-send-400 httpcon "only string tokens supported"))
        ((equal token "") (elnode-send-400 httpcon "token is empty string"))
        ((not username) (elnode-send-400 httpcon "no name specified"))
        ((not (stringp username)) (elnode-send-400 httpcon "only string names supported"))
        ((equal username "") (elnode-send-400 httpcon "name is empty string"))
        ;; Check auth
        ((let ((user-record (db-get username marmalade/users)))
           (not (equal token (kva "token" user-record))))
         (elnode-send-400 httpcon "bad authentication"))
        ;; Check the upload ...
        ((not upload-file) (elnode-send-400 httpcon "no package uploaded"))
        ((not (stringp upload-file)) (elnode-send-400 httpcon "uploaded package is not a string"))
        ((equal upload-file "") (elnode-send-400 httpcon "uploaded package is blank"))
        ;; ... and the upload file name
        ((not upload-file-name) (elnode-send-400 httpcon "uploaded package has no filename"))
        ((equal upload-file-name "") (elnode-send-400 httpcon "uploaded package filename is blank"))
        (t (let ((base-file-name (file-name-nondirectory upload-file-name)))
             ;; This is ripped directly from marmalade/upload - we should abstract probably
             (condition-case err
                 (destructuring-bind (&key info package-path temp-package)
                     (marmalade/save-package upload-file base-file-name)
                   (let* ((package-name (marmalade-pkname info))
                          (package-url (concat "/packages/" package-name))
                          ;; don't have the username here
                          (user-packages (marmalade-get-packages username)))
                     (if (and
                          (file-exists-p (expand-file-name "../.." package-path))
                          (not (member package-name user-packages)))
                         (elnode-send-400
                          httpcon (format "you aren't authorized to update %s" package-name))
                         ;; Else save the package in the store...
                         (marmalade/install-package
                          :info info
                          :package-path package-path
                          :temp-package temp-package
                          :username username)
                         ;; ... send the content of the package as json
                         (let ((json-to-send
                                (append (list (cons "message" "done"))
                                        (list (cons "package" package-name)))))
                           (elnode-send-json httpcon json-to-send))
                         ;; ... and send the request to update the cache
                         (elnode-proxy-post
                          httpcon "/packages/archive-contents/update"
                          :data (list (cons "package-info" (format "%S" info)))))))
               (error
                (when (listp err)
                  (case (marmalade/err->sym err)
                    (:existing-package
                     (elnode-send-400
                      httpcon (format "%S already exists" (cadr err))))))))))))))

(provide 'marmalade-api)

;;; marmalade-api.el ends here
