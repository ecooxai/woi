#include <jni.h>
#include <cstdint>
#include <vector>
#include "woi_echo.h"

extern "C" JNIEXPORT jlong JNICALL
Java_dev_woi_woi_WoiMediaEchoCanceller_nativeCreate(JNIEnv *, jobject, jint rate, jint frame, jint tail) {
    return reinterpret_cast<jlong>(woi_echo_create(rate, frame, tail));
}
extern "C" JNIEXPORT void JNICALL
Java_dev_woi_woi_WoiMediaEchoCanceller_nativeDestroy(JNIEnv *, jobject, jlong handle) {
    woi_echo_destroy(reinterpret_cast<void *>(handle));
}
extern "C" JNIEXPORT void JNICALL
Java_dev_woi_woi_WoiMediaEchoCanceller_nativeReset(JNIEnv *env, jobject, jlong handle) {
    if (!woi_echo_reset(reinterpret_cast<void *>(handle)))
        env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), "Media AEC reset failed");
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_woi_woi_WoiMediaEchoCanceller_nativeProcess(JNIEnv *env, jobject, jlong handle,
                                                   jbyteArray capture, jbyteArray reference) {
    const jsize bytes = env->GetArrayLength(capture);
    if (!handle || bytes != env->GetArrayLength(reference) || (bytes & 1)) {
        env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), "Media AEC requires matching PCM16 frames");
        return nullptr;
    }
    std::vector<int16_t> mic(bytes / 2), far(bytes / 2), out(bytes / 2);
    env->GetByteArrayRegion(capture, 0, bytes, reinterpret_cast<jbyte *>(mic.data()));
    env->GetByteArrayRegion(reference, 0, bytes, reinterpret_cast<jbyte *>(far.data()));
    if (env->ExceptionCheck()) return nullptr;
    if (woi_echo_process(reinterpret_cast<void *>(handle), mic.data(), far.data(), out.data(), bytes / 2) < 0) {
        env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), "Media AEC requires complete processing frames");
        return nullptr;
    }
    jbyteArray result = env->NewByteArray(bytes);
    if (result) env->SetByteArrayRegion(result, 0, bytes, reinterpret_cast<const jbyte *>(out.data()));
    return result;
}
