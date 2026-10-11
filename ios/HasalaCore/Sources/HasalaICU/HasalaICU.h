// Declarations of the ICU C functions CoreTemplate calls, matching ICU's stable C API
// (unicode/uregex.h, unicode/uchar.h). Apple's libicucore exports these names without ICU's
// version suffix, which is what makes declaring them here sufficient; the SDK's libicucore.tbd
// lists every one of them. Only CoreTemplate (Template/Engine) imports this module.
#ifndef HASALA_ICU_H
#define HASALA_ICU_H

#include <stdint.h>

/// ICU's UChar: one UTF-16 code unit.
typedef uint16_t HasalaUChar;
/// ICU's UErrorCode (a C enum, int-sized). Zero is success, positive values are failures.
typedef int32_t HasalaUErrorCode;
/// ICU's UBool.
typedef int8_t HasalaUBool;

/// An opaque compiled regular expression with its own match state. Not thread-safe; clone
/// one per concurrent matcher.
typedef struct URegularExpression URegularExpression;

URegularExpression *uregex_open(const HasalaUChar *pattern, int32_t patternLength, uint32_t flags,
                                void *parseError, HasalaUErrorCode *status);
URegularExpression *uregex_clone(const URegularExpression *regexp, HasalaUErrorCode *status);
void uregex_close(URegularExpression *regexp);
void uregex_setText(URegularExpression *regexp, const HasalaUChar *text, int32_t textLength,
                    HasalaUErrorCode *status);
HasalaUBool uregex_find(URegularExpression *regexp, int32_t startIndex, HasalaUErrorCode *status);
int32_t uregex_groupCount(URegularExpression *regexp, HasalaUErrorCode *status);
int32_t uregex_start(URegularExpression *regexp, int32_t groupNum, HasalaUErrorCode *status);
int32_t uregex_end(URegularExpression *regexp, int32_t groupNum, HasalaUErrorCode *status);
void uregex_setTimeLimit(URegularExpression *regexp, int32_t limit, HasalaUErrorCode *status);
int32_t uregex_getTimeLimit(const URegularExpression *regexp, HasalaUErrorCode *status);
void uregex_setStackLimit(URegularExpression *regexp, int32_t limit, HasalaUErrorCode *status);

/// Simple case folding of one code point (options 0 = U_FOLD_CASE_DEFAULT).
int32_t u_foldCase(int32_t c, uint32_t options);

#endif
