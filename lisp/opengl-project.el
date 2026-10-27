;;; opengl-project.el --- Create GLFW projects -*- lexical-binding: t; -*-

;;; Commentary:
;; Use `opengl-create-project' to create and build a macOS GLFW/GLEW starter.

;;; Code:

(require 'subr-x)
(require 'seq)

(defun opengl-project--slug (name)
  "Convert NAME to a safe lowercase folder name."
  (let ((slug (string-trim
               (replace-regexp-in-string "[^a-z0-9]+" "_" (downcase name))
               "_+" "_+")))
    (when (string-empty-p slug)
      (user-error "Project name must contain at least one ASCII letter or digit"))
    slug))

(defun opengl-project--brew ()
  "Find Homebrew, including standard macOS paths."
  (or (executable-find "brew")
      (seq-find #'file-executable-p
                '("/opt/homebrew/bin/brew" "/usr/local/bin/brew"))
      (user-error "Homebrew is missing; install it from https://brew.sh first")))

(defun opengl-project--run (program &rest args)
  "Run PROGRAM with ARGS, recording output or reporting failure."
  (let ((buffer (get-buffer-create "*OpenGL project*")))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert (format "\n%s %s\n" program (string-join args " "))))
    (unless (eql 0 (apply #'call-process program nil buffer t args))
      (display-buffer buffer)
      (user-error "%s failed; see *OpenGL project*" (file-name-nondirectory program)))))

(defconst opengl-project--main
  "#include <GL/glew.h>
#include <GLFW/glfw3.h>

int main(void)
{
    GLFWwindow* window;

    /* Initialize the library */
    if (!glfwInit())
        return -1;

    /* Create a windowed mode window and its OpenGL context */
    window = glfwCreateWindow(640, 480, \"Hello World\", NULL, NULL);
    if (!window)
    {
        glfwTerminate();
        return -1;
    }

    /* Make the window's context current */
    glfwMakeContextCurrent(window);

    /* Initialize GLEW after making the OpenGL context current */
    glewExperimental = GL_TRUE;
    if (glewInit() != GLEW_OK)
    {
        glfwTerminate();
        return -1;
    }

    /* Loop until the user closes the window */
    while (!glfwWindowShouldClose(window))
    {
        /* Render here */
        glClear(GL_COLOR_BUFFER_BIT);

        /* Swap front and back buffers */
        glfwSwapBuffers(window);

        /* Poll for and process events */
        glfwPollEvents();
    }

    glfwTerminate();
    return 0;
}
"
  "Minimal GLFW/GLEW C++ starter.")

(defconst opengl-project--makefile
  "CXX = clang++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -O2
CPPFLAGS += -DGL_SILENCE_DEPRECATION
BREW ?= %s
GLFW_PREFIX := $(shell $(BREW) --prefix glfw)
GLEW_PREFIX := $(shell $(BREW) --prefix glew)
CPPFLAGS += -I\"$(GLFW_PREFIX)/include\" -I\"$(GLEW_PREFIX)/include\"
LDFLAGS += -L\"$(GLFW_PREFIX)/lib\" -Wl,-rpath,\"$(GLFW_PREFIX)/lib\" -L\"$(GLEW_PREFIX)/lib\" -Wl,-rpath,\"$(GLEW_PREFIX)/lib\"
LDLIBS += -lglfw -lGLEW -framework OpenGL
TARGET := %s

.PHONY: all run clean
all: $(TARGET) compile_commands.json

$(TARGET): main.cpp Makefile
	$(MAKE) --no-print-directory build

compile_commands.json: $(TARGET)
	@test -f \"$@\" || $(MAKE) --no-print-directory build

# Clang emits the actual compiler arguments as a JSON fragment.
.PHONY: build
build:
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) main.cpp -MJ .compile-command.json $(LDFLAGS) $(LDLIBS) -o \"$(TARGET)\"
	{ printf '[\\n'; sed '$$s/,$$//' .compile-command.json; printf ']\\n'; } > compile_commands.json
	rm -f .compile-command.json

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f -- \"$(TARGET)\" compile_commands.json .compile-command.json
"
  "Makefile template, formatted with Homebrew and the executable name.")

;;;###autoload
(defun opengl-create-project (location name)
  "Create and build a GLFW/GLEW project under LOCATION using NAME.
Prompt for both values interactively.  Normalize NAME to a folder name,
install GLFW and GLEW with Homebrew if missing, generate compile_commands.json,
and open main.cpp.  Existing project paths are refused.
Build and installation output is recorded in
the *OpenGL project* buffer.  Requires macOS and command line developer tools."
  (interactive
   (list (read-directory-name "Project location: " (expand-file-name "~/")
                              nil nil)
         (read-string "Project name: ")))
  (unless (eq system-type 'darwin)
    (user-error "This starter uses macOS's OpenGL framework"))
  (when (file-remote-p location)
    (user-error "Choose a local project location"))
  (let* ((slug (opengl-project--slug name))
         (root (expand-file-name slug (file-name-as-directory
                                       (expand-file-name location))))
         (brew (opengl-project--brew))
         (default-directory temporary-file-directory))
    (when (or (file-exists-p root) (file-symlink-p root))
      (user-error "Project path already exists: %s" root))
    (unless (and (executable-find "make") (executable-find "clang++"))
      (user-error "Missing make or clang++; install Apple's command line tools"))
    (with-current-buffer (get-buffer-create "*OpenGL project*")
      (erase-buffer))
    ;; Checking installed versions avoids mistaking a cached formula for an install.
    (dolist (formula '("glfw" "glew"))
      (unless (with-temp-buffer
                (and (eql 0 (call-process brew nil t nil "list" "--versions" formula))
                     (not (string-empty-p (string-trim (buffer-string))))))
        (message "Installing %s with Homebrew..." (upcase formula))
        (opengl-project--run brew "install" formula)))
    (make-directory root t)
    (dolist (file `(("main.cpp" . ,opengl-project--main)
                   ("Makefile" . ,(format opengl-project--makefile
                                          (replace-regexp-in-string
                                           "\\$" "$$" (shell-quote-argument brew) t t)
                                          slug))))
      (with-temp-file (expand-file-name (car file) root)
        (insert (cdr file))))
    (let ((default-directory (file-name-as-directory root)))
      (unwind-protect
          (opengl-project--run (executable-find "make"))
        (find-file (expand-file-name "main.cpp" root))))
    (message "Created and built %s; use make run to launch" root)
    root))

(provide 'opengl-project)
;;; opengl-project.el ends here
