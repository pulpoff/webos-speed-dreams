/*
 * gl4es probe for webOS: does old fixed-function OpenGL (what Speed Dreams' PLIB renderer draws with)
 * run through gl4es on the TV's OpenGL ES 2, and how fast. SDL2 makes the window and a GLES 2 context,
 * gl4es translates. Four phases of 5 s each, from a light scene to a race-like one; the frame rate of
 * each goes to /tmp/glprobe.log. Any key or button ends it early.
 */
#include <SDL2/SDL.h>
#include <GL/gl.h>
#include <gl4esinit.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static SDL_Window *win;

static void fbsize(int *w, int *h) { SDL_GL_GetDrawableSize(win, w, h); }

static GLuint checker(void)
{
	static unsigned char px[256 * 256 * 3];
	GLuint t;
	for (int y = 0; y < 256; y++)
		for (int x = 0; x < 256; x++) {
			int c = ((x >> 5) ^ (y >> 5)) & 1;
			unsigned char *p = &px[(y * 256 + x) * 3];
			p[0] = c ? 90 : 60; p[1] = c ? 140 : 100; p[2] = c ? 70 : 50;
		}
	glGenTextures(1, &t);
	glBindTexture(GL_TEXTURE_2D, t);
	glTexParameteri(GL_TEXTURE_2D, GL_GENERATE_MIPMAP, GL_TRUE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, 256, 256, 0, GL_RGB, GL_UNSIGNED_BYTE, px);
	return t;
}

/* A rolling "track" terrain of n x n quads as client-side vertex arrays, drawn with glDrawElements
 * like PLIB's ssgVtxArray. */
static int tn;
static GLfloat *tv, *tnrm, *ttc;
static GLuint *ti;
static int tcount;

static void make_terrain(int n)
{
	tn = n;
	tv = malloc(sizeof(GLfloat) * 3 * (n + 1) * (n + 1));
	tnrm = malloc(sizeof(GLfloat) * 3 * (n + 1) * (n + 1));
	ttc = malloc(sizeof(GLfloat) * 2 * (n + 1) * (n + 1));
	ti = malloc(sizeof(GLuint) * 6 * n * n);
	for (int z = 0; z <= n; z++)
		for (int x = 0; x <= n; x++) {
			int i = z * (n + 1) + x;
			float fx = (x - n / 2.f) * 4.f, fz = (z - n / 2.f) * 4.f;
			tv[3 * i] = fx; tv[3 * i + 1] = 3.f * sinf(fx * .05f) * cosf(fz * .04f); tv[3 * i + 2] = fz;
			tnrm[3 * i] = 0; tnrm[3 * i + 1] = 1; tnrm[3 * i + 2] = 0;
			ttc[2 * i] = x * .25f; ttc[2 * i + 1] = z * .25f;
		}
	tcount = 0;
	for (int z = 0; z < n; z++)
		for (int x = 0; x < n; x++) {
			GLuint a = z * (n + 1) + x, b = a + 1, c = a + n + 1, d = c + 1;
			ti[tcount++] = a; ti[tcount++] = c; ti[tcount++] = b;
			ti[tcount++] = b; ti[tcount++] = c; ti[tcount++] = d;
		}
}

static void draw_terrain(void)
{
	glEnableClientState(GL_VERTEX_ARRAY);
	glEnableClientState(GL_NORMAL_ARRAY);
	glEnableClientState(GL_TEXTURE_COORD_ARRAY);
	glVertexPointer(3, GL_FLOAT, 0, tv);
	glNormalPointer(GL_FLOAT, 0, tnrm);
	glTexCoordPointer(2, GL_FLOAT, 0, ttc);
	glDrawElements(GL_TRIANGLES, tcount, GL_UNSIGNED_INT, ti);
	glDisableClientState(GL_TEXTURE_COORD_ARRAY);
	glDisableClientState(GL_NORMAL_ARRAY);
	glDisableClientState(GL_VERTEX_ARRAY);
}

/* A "car": a display list of a tessellated sphere squashed into a body, about 2 * seg * seg triangles. */
static GLuint make_car(int seg)
{
	GLuint l = glGenLists(1);
	glNewList(l, GL_COMPILE);
	glBegin(GL_TRIANGLES);
	for (int i = 0; i < seg; i++)
		for (int j = 0; j < seg; j++) {
			float t0 = M_PI * i / seg, t1 = M_PI * (i + 1) / seg, p0 = 2 * M_PI * j / seg, p1 = 2 * M_PI * (j + 1) / seg;
			float v[4][3] = {
				{ sinf(t0) * cosf(p0), cosf(t0), sinf(t0) * sinf(p0) },
				{ sinf(t1) * cosf(p0), cosf(t1), sinf(t1) * sinf(p0) },
				{ sinf(t1) * cosf(p1), cosf(t1), sinf(t1) * sinf(p1) },
				{ sinf(t0) * cosf(p1), cosf(t0), sinf(t0) * sinf(p1) } };
			int q[6] = { 0, 1, 2, 0, 2, 3 };
			for (int k = 0; k < 6; k++) {
				float *p = v[q[k]];
				glNormal3f(p[0], p[1], p[2]);
				glVertex3f(p[0] * 2.2f, p[1] * .6f, p[2] * 1.f);
			}
		}
	glEnd();
	glEndList();
	return l;
}

int main(int argc, char **argv)
{
	(void)argc; (void)argv;
	if (freopen("/tmp/glprobe.log", "w", stdout))
		dup2(fileno(stdout), fileno(stderr));
	setvbuf(stdout, NULL, _IOLBF, 0);
	setenv("SDL_WEBOS_ACCESS_POLICY_KEYS_BACK", "true", 1);

	if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER | SDL_INIT_TIMER) != 0) {
		printf("SDL_Init: %s\n", SDL_GetError());
		return 1;
	}
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
	SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	win = SDL_CreateWindow("glprobe", 0, 0, 1920, 1080, SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN);
	if (!win) { printf("window: %s\n", SDL_GetError()); return 1; }
	SDL_GLContext ctx = SDL_GL_CreateContext(win);
	if (!ctx) { printf("context: %s\n", SDL_GetError()); return 1; }
	set_getprocaddress((void *(*)(const char *))SDL_GL_GetProcAddress);
	set_getmainfbsize(fbsize);
	initialize_gl4es();
	int nosync = access("/tmp/glprobe-nosync", F_OK) == 0;
	SDL_GL_SetSwapInterval(nosync ? 0 : 1);
	printf("swap interval %d\n", nosync ? 0 : 1);

	int w, h, depth = 0;
	SDL_GL_GetDrawableSize(win, &w, &h);
	SDL_GL_GetAttribute(SDL_GL_DEPTH_SIZE, &depth);
	printf("SDL %s, video %s, drawable %dx%d, depth %d\n", SDL_GetRevision(), SDL_GetCurrentVideoDriver(), w, h, depth);
	printf("GL_VENDOR %s\nGL_RENDERER %s\nGL_VERSION %s\n", glGetString(GL_VENDOR), glGetString(GL_RENDERER), glGetString(GL_VERSION));

	GLuint tex = checker();
	make_terrain(200);			/* 80 000 triangles */
	GLuint car = make_car(48);		/* 4 608 triangles each */
	printf("terrain %d triangles, car %d triangles\n", tcount / 3, 2 * 48 * 48);

	glViewport(0, 0, w, h);
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	float zn = .5f, zf = 1000.f, fy = zn * tanf(30.f * M_PI / 180.f), fx = fy * w / h;
	glFrustum(-fx, fx, -fy, fy, zn, zf);
	glMatrixMode(GL_MODELVIEW);
	glEnable(GL_DEPTH_TEST);
	glEnable(GL_CULL_FACE);
	glEnable(GL_LIGHTING);
	glEnable(GL_LIGHT0);
	glEnable(GL_COLOR_MATERIAL);
	glEnable(GL_NORMALIZE);
	GLfloat lpos[4] = { .3f, 1.f, .4f, 0.f }, fogc[4] = { .55f, .65f, .8f, 1.f };
	glLightfv(GL_LIGHT0, GL_POSITION, lpos);
	glEnable(GL_FOG);
	glFogi(GL_FOG_MODE, GL_LINEAR);
	glFogf(GL_FOG_START, 100.f);
	glFogf(GL_FOG_END, 500.f);
	glFogfv(GL_FOG_COLOR, fogc);
	glClearColor(fogc[0], fogc[1], fogc[2], 1.f);

	static const struct { const char *name; int terrain, cars, layers; } phase[] = {
		{ "1 clear screen + one car", 0, 1, 0 },
		{ "2 terrain 80k tris, textured, lit, fog", 1, 0, 0 },
		{ "3 terrain + 6 cars (108k tris)", 1, 6, 0 },
		{ "4 terrain + 20 cars (172k tris)", 1, 20, 0 },
		{ "5 terrain x4 + 20 cars (412k tris)", 4, 20, 0 },
		{ "6 terrain + 20 cars + 4 full-screen blended layers", 1, 20, 4 },
	};
	const int nphase = sizeof(phase) / sizeof(phase[0]);
	Uint32 start = SDL_GetTicks();
	int ph = 0, frames = 0;
	Uint32 pstart = start;
	for (int running = 1; running && ph < nphase;) {
		SDL_Event e;
		while (SDL_PollEvent(&e))
			if (e.type == SDL_QUIT || e.type == SDL_KEYDOWN || e.type == SDL_CONTROLLERBUTTONDOWN)
				running = 0;
		float t = (SDL_GetTicks() - start) / 1000.f;
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		glLoadIdentity();
		glRotatef(12.f, 1, 0, 0);
		glRotatef(t * 20.f, 0, 1, 0);
		glTranslatef(0, -8.f, 0);
		glLightfv(GL_LIGHT0, GL_POSITION, lpos);
		for (int k = 0; k < phase[ph].terrain; k++) {
			glPushMatrix();
			glTranslatef(0, -.05f * k, 0);
			glEnable(GL_TEXTURE_2D);
			glBindTexture(GL_TEXTURE_2D, tex);
			glColor3f(1, 1, 1);
			draw_terrain();
			glDisable(GL_TEXTURE_2D);
			glPopMatrix();
		}
		for (int c = 0; c < phase[ph].cars; c++) {
			glPushMatrix();
			float a = c * 2.f * M_PI / (phase[ph].cars > 1 ? phase[ph].cars : 1) + t * .5f;
			glTranslatef(cosf(a) * 25.f, 3.f, sinf(a) * 25.f - (phase[ph].cars == 1 ? 15.f : 0));
			glColor3f(.8f, .2f + .03f * c, .2f);
			glCallList(car);
			glPopMatrix();
		}
		if (phase[ph].layers) {
			glMatrixMode(GL_PROJECTION); glPushMatrix(); glLoadIdentity();
			glMatrixMode(GL_MODELVIEW); glPushMatrix(); glLoadIdentity();
			glDisable(GL_LIGHTING); glDisable(GL_DEPTH_TEST); glDisable(GL_FOG);
			glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
			glEnable(GL_TEXTURE_2D); glBindTexture(GL_TEXTURE_2D, tex);
			for (int k = 0; k < phase[ph].layers; k++) {
				glColor4f(1, 1, 1, .08f);
				glBegin(GL_QUADS);
				glTexCoord2f(0, 0); glVertex2f(-1, -1); glTexCoord2f(4, 0); glVertex2f(1, -1);
				glTexCoord2f(4, 4); glVertex2f(1, 1); glTexCoord2f(0, 4); glVertex2f(-1, 1);
				glEnd();
			}
			glDisable(GL_TEXTURE_2D); glDisable(GL_BLEND);
			glEnable(GL_LIGHTING); glEnable(GL_DEPTH_TEST); glEnable(GL_FOG);
			glMatrixMode(GL_PROJECTION); glPopMatrix(); glMatrixMode(GL_MODELVIEW); glPopMatrix();
		}
		SDL_GL_SwapWindow(win);
		frames++;
		Uint32 now = SDL_GetTicks();
		if (now - pstart >= 5000) {
			printf("phase %s: %.1f fps\n", phase[ph].name, frames * 1000.f / (now - pstart));
			ph++;
			frames = 0;
			pstart = now;
		}
	}
	GLenum err = glGetError();
	printf("glGetError 0x%x; done\n", err);
	SDL_GL_DeleteContext(ctx);
	SDL_DestroyWindow(win);
	SDL_Quit();
	return 0;
}
