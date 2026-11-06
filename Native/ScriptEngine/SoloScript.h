#ifndef SOLO_SCRIPT_H
#define SOLO_SCRIPT_H
// Opaque QuickJS runtime. All calls except interrupt/free_string are serialized
// on one worker queue. No filesystem, network, module loader or credentials.
typedef struct SoloScript SoloScript;
SoloScript *solo_js_create(void);
void solo_js_destroy(SoloScript *runtime);
char *solo_js_begin(SoloScript *runtime, const char *code);
char *solo_js_step(SoloScript *runtime, const char *response_json);
// Discard a suspended script's pending operation without erasing global state.
void solo_js_discard_run(SoloScript *runtime);
void solo_js_interrupt(SoloScript *runtime);
void solo_js_free_string(char *value);
#endif
