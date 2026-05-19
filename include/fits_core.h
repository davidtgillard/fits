#ifndef FITS_CORE_H
#define FITS_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- Version and memory --- */

#define FITS_API_VERSION_MAJOR 0
#define FITS_API_VERSION_MINOR 1
#define FITS_API_VERSION_PACKED ((FITS_API_VERSION_MAJOR << 16) | FITS_API_VERSION_MINOR)

uint32_t fits_api_version(void);
const char *fits_version_string(void);
void fits_free(void *ptr);
const char *fits_last_error(void);

/* --- Status codes --- */

typedef int32_t FitsStatus;

#define FITS_OK 0
#define FITS_ERR_INVALID_ARGUMENT -1
#define FITS_ERR_REPO_NOT_FOUND -2
#define FITS_ERR_REGISTRY -3
#define FITS_ERR_LINKS_INVALID -4
#define FITS_ERR_SNAPSHOT_MISMATCH -5
#define FITS_ERR_UNKNOWN_ID_PREFIX -6
#define FITS_ERR_ALREADY_INITIALIZED -7
#define FITS_ERR_OUT_OF_MEMORY -8
#define FITS_ERR_IO -9
#define FITS_ERR_NOT_IMPLEMENTED -10
#define FITS_ERR_INTERNAL -11

/* --- Severity and findings --- */

typedef int32_t FitsSeverity;

#define FITS_SEVERITY_INFO 0
#define FITS_SEVERITY_WARN 1
#define FITS_SEVERITY_ERR 2

typedef struct FitsFinding {
    uint32_t struct_size;
    FitsSeverity severity;
    const char *code;
    const char *message;
    const char *object_id; /* NULL when not applicable */
} FitsFinding;

typedef struct FitsValidateSummary {
    uint32_t struct_size;
    size_t total_findings;
    size_t info_count;
    size_t warning_count;
    size_t error_count;
} FitsValidateSummary;

typedef struct FitsValidateResult {
    uint32_t struct_size;
    FitsFinding *findings;
    size_t findings_len;
    FitsValidateSummary summary;
} FitsValidateResult;

/* --- Repo session --- */

typedef struct FitsRepo FitsRepo;

typedef struct FitsRepoOpenOptions {
    uint32_t struct_size;
    const char *repo_root;
    const char *registry_snapshot_path; /* NULL: no fixed-schema enforcement */
} FitsRepoOpenOptions;

typedef struct FitsValidateOptions {
    uint32_t struct_size;
    int32_t include_link_endpoints; /* 0 or 1 */
} FitsValidateOptions;

typedef struct FitsNewNodeOptions {
    uint32_t struct_size;
    const char *id_prefix;
    int32_t markdown; /* 0 or 1 */
    const char *title; /* optional; NULL for empty */
} FitsNewNodeOptions;

typedef struct FitsNewLinkOptions {
    uint32_t struct_size;
    const char *link_type;
    const char *in_id;
    const char *out_id;
} FitsNewLinkOptions;

typedef struct FitsRegisterNodeTypeOptions {
    uint32_t struct_size;
    const char *type_name;
    int32_t abstract; /* 0 or 1 */
    const char *extends; /* required when abstract == 0 */
    int32_t create_folder; /* 0 or 1 */
} FitsRegisterNodeTypeOptions;

typedef struct FitsRegisterLinkTypeOptions {
    uint32_t struct_size;
    const char *link_type;
    const char *in_type;
    const char *out_type;
    int32_t create_folder; /* 0 or 1 */
} FitsRegisterLinkTypeOptions;

typedef struct FitsRepoInitOptions {
    uint32_t struct_size;
    int32_t no_interactive;
    int32_t init_git;
    int32_t edit_gitignore;
} FitsRepoInitOptions;

FitsRepo *fits_repo_open(const FitsRepoOpenOptions *options);
void fits_repo_close(FitsRepo *repo);

FitsStatus fits_repo_init(FitsRepo *repo, const FitsRepoInitOptions *options);

FitsStatus fits_registry_register_node_type(FitsRepo *repo, const FitsRegisterNodeTypeOptions *options);
FitsStatus fits_registry_register_link_type(FitsRepo *repo, const FitsRegisterLinkTypeOptions *options);
FitsStatus fits_registry_verify_snapshot(FitsRepo *repo);

FitsStatus fits_new_node(FitsRepo *repo, const FitsNewNodeOptions *options, char **out_node_id);
FitsStatus fits_new_link(FitsRepo *repo, const FitsNewLinkOptions *options);
FitsStatus fits_remove(FitsRepo *repo, const char *object_id);

FitsStatus fits_validate(FitsRepo *repo, const FitsValidateOptions *options, FitsValidateResult **out_result);
void fits_validate_result_destroy(FitsValidateResult *result);

#ifdef __cplusplus
}
#endif

#endif /* FITS_CORE_H */
