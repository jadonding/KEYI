#include "KEYIHTTP.h"

#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static pthread_once_t curlOnce = PTHREAD_ONCE_INIT;
static CURLcode curlInitialization;
static const size_t maxResponseBytes = 8 * 1024 * 1024;

static void initializeCurl(void) {
    curlInitialization = curl_global_init(CURL_GLOBAL_DEFAULT);
}

struct Transfer {
    KEYIHTTPResponse *response;
    KEYIHTTPIsCancelled isCancelled;
    void *context;
    size_t capacity;
};

static size_t writeResponse(char *bytes, size_t size, size_t count, void *context) {
    struct Transfer *transfer = context;
    KEYIHTTPResponse *response = transfer->response;
    if (size == 0 || count > (maxResponseBytes - response->length) / size) {
        return 0;
    }
    size_t length = size * count;
    size_t end = response->length + length;
    if (end > transfer->capacity) {
        size_t capacity = transfer->capacity * 2;
        if (capacity < end) {
            capacity = end;
        }
        if (capacity > maxResponseBytes) {
            capacity = maxResponseBytes;
        }
        uint8_t *buffer = realloc(response->body, capacity);
        if (!buffer) {
            return 0;
        }
        response->body = buffer;
        transfer->capacity = capacity;
    }
    if (length > 0) {
        memcpy(response->body + response->length, bytes, length);
        response->length = end;
    }
    return length;
}

static int checkCancellation(
    void *context, curl_off_t downloadTotal, curl_off_t downloaded,
    curl_off_t uploadTotal, curl_off_t uploaded
) {
    (void)downloadTotal;
    (void)downloaded;
    (void)uploadTotal;
    (void)uploaded;
    struct Transfer *transfer = context;
    return transfer->isCancelled(transfer->context);
}

int KEYIHTTPPost(
    const char *url, const char *authorizationHeader, const void *body, size_t length,
    long timeoutMilliseconds, KEYIHTTPIsCancelled isCancelled, void *context,
    KEYIHTTPResponse *response
) {
    *response = (KEYIHTTPResponse){0};
    pthread_once(&curlOnce, initializeCurl);
    if (curlInitialization != CURLE_OK) {
        return curlInitialization;
    }
    if (isCancelled(context)) {
        return CURLE_ABORTED_BY_CALLBACK;
    }

    CURL *curl = curl_easy_init();
    if (!curl) {
        return CURLE_FAILED_INIT;
    }
    struct curl_slist *headers = curl_slist_append(NULL, "Content-Type: application/json");
    struct curl_slist *completeHeaders = headers ? curl_slist_append(headers, authorizationHeader) : NULL;
    CURLcode code = CURLE_OUT_OF_MEMORY;
    if (!completeHeaders) {
        goto cleanup;
    }
    headers = completeHeaders;
    struct Transfer transfer = {response, isCancelled, context, 0};
    code = curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http");
    if (code != CURLE_OK) {
        goto cleanup;
    }
    curl_easy_setopt(curl, CURLOPT_URL, url);
    // Keep the key and request body at the endpoint the user configured.
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)length);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, timeoutMilliseconds);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeResponse);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &transfer);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, checkCancellation);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &transfer);
    code = curl_easy_perform(curl);
    if (code == CURLE_OK) {
        code = curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response->status);
    }

cleanup:
    curl_easy_cleanup(curl);
    curl_slist_free_all(headers);
    if (code != CURLE_OK) {
        free(response->body);
        *response = (KEYIHTTPResponse){0};
    }
    return code;
}

const char *KEYIHTTPErrorDescription(int code) {
    return curl_easy_strerror((CURLcode)code);
}

int KEYIHTTPErrorIsTimeout(int code) {
    return code == CURLE_OPERATION_TIMEDOUT;
}
