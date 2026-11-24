#ifndef KEYIHTTP_H
#define KEYIHTTP_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    long status;
    uint8_t *body;
    size_t length;
} KEYIHTTPResponse;

typedef int (*KEYIHTTPIsCancelled)(void *context);

/// On success, the caller owns response->body and releases it with free().
int KEYIHTTPPost(
    const char *url,
    const char *authorizationHeader,
    const void *body,
    size_t length,
    long timeoutMilliseconds,
    KEYIHTTPIsCancelled isCancelled,
    void *context,
    KEYIHTTPResponse *response
);

const char *KEYIHTTPErrorDescription(int code);
int KEYIHTTPErrorIsTimeout(int code);

#endif
