#include "SoloScript.h"
#include "../QuickJS/quickjs.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct SoloScript {
    JSRuntime *rt;
    JSContext *ctx;
    JSValue root, resolve, reject, logs;
    char *request;
    atomic_int cancelled;
    double deadline;
    int interrupted;
    unsigned log_count, log_bytes, logs_omitted;
};
static double monotonic(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec + time.tv_nsec / 1e9;
}
static int interrupted(JSRuntime *rt, void *opaque) {
    (void)rt;
    SoloScript *s = opaque;
    if (atomic_load(&s->cancelled)) { s->interrupted = 1; return 1; }
    if (monotonic() > s->deadline) { s->interrupted = 2; return 1; }
    return 0;
}
static JSValue phone_call(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
    (void)self;
    SoloScript *s = JS_GetContextOpaque(ctx);
    if (s->request) return JS_ThrowTypeError(ctx, "Await each phone operation; parallel calls are not supported");
    if (argc != 2) return JS_ThrowTypeError(ctx, "Expected operation name and arguments");
    JSValue object = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, object, "name", JS_DupValue(ctx, argv[0]));
    JS_SetPropertyStr(ctx, object, "arguments", JS_DupValue(ctx, argv[1]));
    JSValue json = JS_JSONStringify(ctx, object, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, object);
    if (JS_IsException(json)) return json;
    size_t size = 0;
    const char *text = JS_ToCStringLen(ctx, &size, json);
    if (!text || size > 64000) {
        if (text) JS_FreeCString(ctx, text);
        JS_FreeValue(ctx, json);
        return JS_ThrowRangeError(ctx, "Phone arguments exceed 64 KB");
    }
    s->request = strndup(text, size);
    JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, json);
    if (!s->request) return JS_ThrowOutOfMemory(ctx);
    JSValue callbacks[2];
    JSValue promise = JS_NewPromiseCapability(ctx, callbacks);
    if (JS_IsException(promise)) { free(s->request); s->request = NULL; return promise; }
    s->resolve = callbacks[0]; s->reject = callbacks[1];
    return promise;
}
static JSValue log_value(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
    (void)self;
    SoloScript *s = JS_GetContextOpaque(ctx);
    if (s->log_count >= 100 || s->log_bytes >= 64000) {
        s->logs_omitted++;
        return JS_UNDEFINED;
    }
    JSValue value = argc > 0 ? argv[0] : JS_UNDEFINED;
    JSValue json = JS_IsString(value) ? JS_DupValue(ctx, value) : JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json)) return json;
    size_t size = 0;
    const char *text = JS_ToCStringLen(ctx, &size, json);
    JS_FreeValue(ctx, json);
    if (!text) return JS_EXCEPTION;
    if (size + s->log_bytes > 64000) {
        size = 64000 - s->log_bytes;
        while (size && ((unsigned char)text[size] & 0xc0) == 0x80) size--;
        s->logs_omitted++;
    }
    s->log_bytes += (unsigned)size;
    JS_SetPropertyUint32(ctx, s->logs, s->log_count++, JS_NewStringLen(ctx, text, size));
    JS_FreeCString(ctx, text);
    return JS_UNDEFINED;
}
static void clear_run(SoloScript *s) {
    JS_FreeValue(s->ctx, s->root); s->root = JS_UNDEFINED;
    JS_FreeValue(s->ctx, s->resolve); s->resolve = JS_UNDEFINED;
    JS_FreeValue(s->ctx, s->reject); s->reject = JS_UNDEFINED;
    JS_FreeValue(s->ctx, s->logs); s->logs = JS_NewArray(s->ctx);
    free(s->request); s->request = NULL;
    s->log_count = s->log_bytes = s->logs_omitted = 0;
}
static char *packet(SoloScript *s, const char *state, const char *error) {
    JSContext *ctx = s->ctx;
    // Serialization itself remains interruptible and bounded.
    s->deadline = monotonic() + 0.5;
    atomic_store(&s->cancelled, 0);
    JSValue result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "state", JS_NewString(ctx, state));
    JS_SetPropertyStr(ctx, result, "logs", JS_DupValue(ctx, s->logs));
    JS_SetPropertyStr(ctx, result, "logs_omitted", JS_NewUint32(ctx, s->logs_omitted));
    if (error) JS_SetPropertyStr(ctx, result, "error", JS_NewString(ctx, error));
    if (!strcmp(state, "request") && s->request) {
        JS_SetPropertyStr(ctx, result, "request", JS_ParseJSON(ctx, s->request, strlen(s->request), "phone-request"));
    }
    JSValue json = JS_JSONStringify(ctx, result, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, result);
    const char *text = JS_IsException(json) ? NULL : JS_ToCString(ctx, json);
    char *output = strdup(text ? text : "{\"state\":\"error\",\"error\":\"JavaScript memory or output limit reached\",\"logs\":[]}");
    if (text) JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, json);
    JS_FreeValue(ctx, s->logs); s->logs = JS_NewArray(ctx); s->log_count = 0; s->logs_omitted = 0;
    return output;
}
static char *exception_packet(SoloScript *s, JSValue error) {
    const char *text = JS_ToCString(s->ctx, error);
    const char *message = s->interrupted == 1 ? "JavaScript cancelled" :
                          s->interrupted == 2 ? "JavaScript CPU slice exceeded 2 seconds" :
                          text ? text : "JavaScript evaluation failed";
    char *copy = strndup(message, 2000);
    if (text) JS_FreeCString(s->ctx, text);
    JS_FreeValue(s->ctx, error);
    char *result = packet(s, "error", copy ? copy : "JavaScript error");
    free(copy);
    return result;
}
static const char *bootstrap =
"'use strict';"
"Object.defineProperty(globalThis,'state',{value:{},writable:false});"
"const __api = {};"
"for(const [name,op] of Object.entries({observe:'observe',listApps:'list_apps',openApp:'open_app',tap:'tap',doubleTap:'double_tap',longPress:'long_press',swipe:'swipe',typeText:'type_text',pasteText:'paste_text',pasteAt:'paste_at',finishPaste:'finish_paste',pressKey:'press_key',home:'home',wait:'wait'})){"
" __api[name]=async function(args={}){const r=await __phone(op,args);if(r.status!=='executed'){const e=new Error(r.error?.message||'Phone operation failed');e.code=r.error?.code;e.status=r.status;throw e;}return r.value;};}"
"Object.defineProperty(globalThis,'phone',{value:Object.freeze(__api),writable:false});"
"Object.defineProperty(globalThis,'console',{value:Object.freeze({log:log}),writable:false});"
"delete globalThis.SharedArrayBuffer; delete globalThis.Atomics;";
SoloScript *solo_js_create(void) {
    SoloScript *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->rt = JS_NewRuntime();
    if (!s->rt) { free(s); return NULL; }
    JS_SetMemoryLimit(s->rt, 32 * 1024 * 1024);
    JS_SetMaxStackSize(s->rt, 256 * 1024);
    JS_SetCanBlock(s->rt, 0);
    s->ctx = JS_NewContext(s->rt);
    if (!s->ctx) { JS_FreeRuntime(s->rt); free(s); return NULL; }
    s->root = s->resolve = s->reject = JS_UNDEFINED;
    s->logs = JS_NewArray(s->ctx);
    JS_SetContextOpaque(s->ctx, s);
    JS_SetInterruptHandler(s->rt, interrupted, s);
    s->deadline = monotonic() + 2;
    JSValue global = JS_GetGlobalObject(s->ctx);
    JS_DefinePropertyValueStr(s->ctx, global, "__phone", JS_NewCFunction(s->ctx, phone_call, "__phone", 2), 0);
    JS_DefinePropertyValueStr(s->ctx, global, "log", JS_NewCFunction(s->ctx, log_value, "log", 1), 0);
    JS_FreeValue(s->ctx, global);
    JSValue result = JS_Eval(s->ctx, bootstrap, strlen(bootstrap), "phone-runtime", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(result)) { JS_FreeValue(s->ctx, result); solo_js_destroy(s); return NULL; }
    JS_FreeValue(s->ctx, result);
    return s;
}
void solo_js_destroy(SoloScript *s) {
    if (!s) return;
    JS_UpdateStackTop(s->rt);
    clear_run(s);
    JS_FreeValue(s->ctx, s->logs);
    JS_FreeContext(s->ctx); JS_FreeRuntime(s->rt); free(s);
}
void solo_js_interrupt(SoloScript *s) { if (s) atomic_store(&s->cancelled, 1); }
void solo_js_discard_run(SoloScript *s) {
    if (!s) return;
    JS_UpdateStackTop(s->rt);
    clear_run(s);
}
void solo_js_free_string(char *value) { free(value); }
char *solo_js_begin(SoloScript *s, const char *code) {
    if (!s || !code) return NULL;
    // A serial GCD queue can migrate between OS threads after an async device
    // operation. Refresh QuickJS's stack origin before re-entering the engine.
    JS_UpdateStackTop(s->rt);
    clear_run(s);
    atomic_store(&s->cancelled, 0);
    s->interrupted = 0; s->deadline = monotonic() + 2;
    size_t len = strlen(code);
    if (len > 64000) return packet(s, "error", "Script exceeds 64 KB");
    char *wrapped = malloc(len + 64);
    if (!wrapped) return packet(s, "error", "Cannot allocate script");
    strcpy(wrapped, "(async()=>{ 'use strict';\n"); strcat(wrapped, code); strcat(wrapped, "\n})()");
    s->root = JS_Eval(s->ctx, wrapped, strlen(wrapped), "agent-script.js", JS_EVAL_TYPE_GLOBAL);
    free(wrapped);
    if (JS_IsException(s->root)) return exception_packet(s, JS_GetException(s->ctx));
    return solo_js_step(s, NULL);
}
char *solo_js_step(SoloScript *s, const char *response) {
    if (!s) return NULL;
    JS_UpdateStackTop(s->rt);
    s->deadline = monotonic() + 2;
    if (response) {
        if (!s->request) return packet(s, "error", "No phone request is waiting");
        JSValue value = JS_ParseJSON(s->ctx, response, strlen(response), "phone-result");
        if (JS_IsException(value)) return exception_packet(s, JS_GetException(s->ctx));
        JSValue result = JS_Call(s->ctx, s->resolve, JS_UNDEFINED, 1, &value);
        JS_FreeValue(s->ctx, result); JS_FreeValue(s->ctx, value);
        JS_FreeValue(s->ctx, s->resolve); s->resolve = JS_UNDEFINED;
        JS_FreeValue(s->ctx, s->reject); s->reject = JS_UNDEFINED;
        free(s->request); s->request = NULL;
    }
    JSContext *jobContext = NULL;
    while (JS_IsJobPending(s->rt)) {
        if (interrupted(s->rt, s)) return packet(s, "error", s->interrupted == 1 ? "JavaScript cancelled" : "JavaScript CPU slice exceeded 2 seconds");
        if (JS_ExecutePendingJob(s->rt, &jobContext) < 0) return exception_packet(s, JS_GetException(jobContext ? jobContext : s->ctx));
    }
    JSPromiseStateEnum state = JS_PromiseState(s->ctx, s->root);
    if (state == JS_PROMISE_REJECTED) return exception_packet(s, JS_PromiseResult(s->ctx, s->root));
    if (state == JS_PROMISE_FULFILLED) {
        if (s->request) return packet(s, "error", "Unawaited phone operation discarded; await every phone call");
        return packet(s, "done", NULL);
    }
    if (s->request) return packet(s, "request", NULL);
    return packet(s, "error", "Script is waiting without a phone request; external async APIs are unavailable");
}
