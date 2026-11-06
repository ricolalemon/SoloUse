#include "../Native/ScriptEngine/SoloScript.h"
#include <pthread.h>
#include <assert.h>
#include <string.h>
#include <stdio.h>
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition=PTHREAD_COND_INITIALIZER;
static SoloScript *runtime;
static int ready,done;
static void *creator(void *arg) {
    (void)arg;
    SoloScript *r=solo_js_create(); assert(r);
    char *result=solo_js_begin(r,"state.n=73; await phone.home(); log(state.n);");
    assert(result && strstr(result,"request")); solo_js_free_string(result);
    pthread_mutex_lock(&mutex); runtime=r; ready=1; pthread_cond_signal(&condition);
    while(!done) pthread_cond_wait(&condition,&mutex);
    pthread_mutex_unlock(&mutex);
    return NULL;
}
int main(void) {
    pthread_t thread; assert(pthread_create(&thread,NULL,creator,NULL)==0);
    pthread_mutex_lock(&mutex);
    while(!ready) pthread_cond_wait(&condition,&mutex);
    pthread_mutex_unlock(&mutex);
    char *result=solo_js_step(runtime,"{\"status\":\"executed\",\"value\":{}}");
    assert(result && strstr(result,"done") && strstr(result,"73")); solo_js_free_string(result);
    result=solo_js_begin(runtime,"log(state.n+1);");
    assert(result && strstr(result,"done") && strstr(result,"74")); solo_js_free_string(result);
    solo_js_destroy(runtime);
    pthread_mutex_lock(&mutex); done=1; pthread_cond_signal(&condition); pthread_mutex_unlock(&mutex);
    pthread_join(thread,NULL);
    puts("PASS interpreter continuation and persistent variables across different OS threads");
}
