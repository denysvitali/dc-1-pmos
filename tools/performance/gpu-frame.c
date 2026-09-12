/* Offscreen fill/completion probe, not a compositor or scanout benchmark. */
#define _POSIX_C_SOURCE 200809L
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void fail(const char *message)
{
	fprintf(stderr, "gpu-frame: %s\n", message);
	exit(1);
}

static double now_ms(void)
{
	struct timespec ts;
	if (clock_gettime(CLOCK_MONOTONIC, &ts))
		fail("clock_gettime failed");
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

static GLuint shader(GLenum kind, const char *source)
{
	GLuint id = glCreateShader(kind);
	GLint ok;
	glShaderSource(id, 1, &source, NULL);
	glCompileShader(id);
	glGetShaderiv(id, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[2048];
		glGetShaderInfoLog(id, sizeof(log), NULL, log);
		fprintf(stderr, "%s\n", log);
		fail("shader compilation failed");
	}
	return id;
}

static int compare(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static long number(const char *text, long min, long max)
{
	char *end;
	errno = 0;
	long value = strtol(text, &end, 10);
	if (errno || end == text || *end || value < min || value > max)
		fail("expected samples 1..1000 and idle milliseconds 0..1000");
	return value;
}

int main(int argc, char **argv)
{
	if (argc > 3) {
		fprintf(stderr, "usage: gpu-frame [samples=60] [idle-ms=100]\n");
		return 2;
	}
	int samples = argc > 1 ? number(argv[1], 1, 1000) : 60;
	int idle_ms = argc > 2 ? number(argv[2], 0, 1000) : 100;
	PFNEGLGETPLATFORMDISPLAYEXTPROC get_display =
		(PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
	if (!get_display)
		fail("EGL platform display extension unavailable");
	EGLDisplay display = get_display(EGL_PLATFORM_SURFACELESS_MESA,
	                                 EGL_DEFAULT_DISPLAY, NULL);
	if (display == EGL_NO_DISPLAY || !eglInitialize(display, NULL, NULL))
		fail("cannot initialize surfaceless EGL");
	const EGLint config_attrs[] = {
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_NONE
	};
	EGLConfig config;
	EGLint count;
	if (!eglChooseConfig(display, config_attrs, &config, 1, &count) || count != 1 ||
	    !eglBindAPI(EGL_OPENGL_ES_API))
		fail("no GLES2 EGL configuration");
	const EGLint context_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attrs);
	const EGLint surface_attrs[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
	EGLSurface surface = eglCreatePbufferSurface(display, config, surface_attrs);
	if (context == EGL_NO_CONTEXT || surface == EGL_NO_SURFACE ||
	    !eglMakeCurrent(display, surface, surface, context))
		fail("cannot make GLES2 context current");
	printf("renderer=%s\nversion=%s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));

	GLuint texture, fbo;
	glGenTextures(1, &texture);
	glBindTexture(GL_TEXTURE_2D, texture);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1200, 1600, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
		fail("incomplete framebuffer");
	GLuint vertex = shader(GL_VERTEX_SHADER,
		"attribute vec2 position; void main() { gl_Position = vec4(position, 0., 1.); }");
	GLuint fragment = shader(GL_FRAGMENT_SHADER,
		"precision mediump float; void main() { gl_FragColor = vec4(.2, .4, .6, .5); }");
	GLuint program = glCreateProgram();
	glAttachShader(program, vertex);
	glAttachShader(program, fragment);
	glBindAttribLocation(program, 0, "position");
	glLinkProgram(program);
	GLint linked;
	glGetProgramiv(program, GL_LINK_STATUS, &linked);
	if (!linked)
		fail("shader program link failed");
	glUseProgram(program);
	const GLfloat vertices[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, vertices);
	glEnableVertexAttribArray(0);
	glViewport(0, 0, 1200, 1600);
	glEnable(GL_BLEND);
	glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	glClearColor(0, 0, 0, 0);
	double timings[1000];
	/* Warm shader caches before timing. Every timed sample waits for GPU
	 * completion; idle mode gives autosuspend a chance between samples. */
	for (int i = -10; i < samples; i++) {
		if (i >= 0 && idle_ms) {
			struct timespec delay = { idle_ms / 1000, (idle_ms % 1000) * 1000000L };
			while (nanosleep(&delay, &delay))
				if (errno != EINTR)
					fail("nanosleep failed");
		}
		double start = now_ms();
		glClear(GL_COLOR_BUFFER_BIT);
		for (int layer = 0; layer < 8; layer++)
			glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		glFinish();
		double elapsed = now_ms() - start;
		if (glGetError() != GL_NO_ERROR)
			fail("GL error while rendering");
		if (i >= 0)
			timings[i] = elapsed;
	}
	/* Positive control: reject a fast run which failed to draw the layers. */
	GLubyte pixel[4];
	glReadPixels(600, 800, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
	if (glGetError() != GL_NO_ERROR || pixel[0] < 45 || pixel[0] > 60 ||
	    pixel[1] < 95 || pixel[1] > 110 || pixel[2] < 145 || pixel[2] > 160)
		fail("rendered pixel validation failed");
	qsort(timings, samples, sizeof(timings[0]), compare);
	printf("width=1200\nheight=1600\nlayers=8\nsamples=%d\nidle_ms=%d\n"
	       "p50_ms=%.3f\np95_ms=%.3f\nmax_ms=%.3f\npixel_check=pass\n",
	       samples, idle_ms, timings[(samples - 1) / 2],
	       timings[(95 * samples + 99) / 100 - 1], timings[samples - 1]);
	glDeleteProgram(program);
	glDeleteShader(vertex);
	glDeleteShader(fragment);
	glDeleteFramebuffers(1, &fbo);
	glDeleteTextures(1, &texture);
	eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroySurface(display, surface);
	eglDestroyContext(display, context);
	eglTerminate(display);
	return 0;
}
