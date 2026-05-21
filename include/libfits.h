/**
 * @file libfits.h
 * @brief JSON-over-C ABI for libfits.
 *
 * libfits exposes two C-compatible layers. This header is the JSON layer: each
 * function accepts a UTF-8 JSON request body and writes a UTF-8 JSON response.
 * Symbols use the `FITS_` prefix (for example `FITS_validate`, `FITS_remove_obj`).
 * The struct-based core API lives in fits_core.h (`FITS_CORE_validate`,
 * `FITS_CORE_new_node`, and related symbols).
 *
 * Request and response payload shapes are defined under `schemas/abi/` and summarized
 * in `docs/abi.md`.
 *
 * @par Memory
 * On success or structured failure, each operation's `*_response_json` out pointer is
 * set to a newly allocated null-terminated UTF-8 document. The caller must release
 * it with FITS_free(). All heap allocations crossing this boundary use the C allocator.
 *
 * @par Errors
 * Functions return FitsStatus (`FITS_OK` == 0; negative codes are defined in
 * fits_core.h). After a failure, FITS_last_error() may contain a short diagnostic
 * valid until the next libfits call on the same thread.
 *
 * When the operation fails, the response out pointer is still set to a document of
 * the form `{ "ok": false, "error": { "code", "message" } }` unless that pointer
 * argument itself is NULL.
 *
 * @par Threading
 * Use one FitsRepo handle per thread; do not share handles across threads without
 * external locking.
 *
 * @see docs/abi.md
 * @see fits_core.h
 */

#ifndef LIBFITS_H
#define LIBFITS_H

#include "fits_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Validate the repository graph and return structured validation issues.
 *
 * Runs validation on the open repository and returns a report of info, warning,
 * and error validation issues. A successful call (`FITS_OK`) means validation completed;
 * individual validation issues may still report errors in the graph.
 *
 * @param repo Open repository handle from FITS_CORE_repo_open(). Must not be NULL.
 * @param validate_request_json UTF-8 JSON request body, or NULL to use defaults (`{}`).
 *        Optional fields:
 *        - `protocol_version` (integer, currently `1`)
 *        - `include_link_endpoints` (boolean, default `true`)
 *        Schema: `schemas/abi/validate_request.schema.json`
 * @param validate_response_json Out pointer. On return, set to an allocated response
 *        document. Must not be NULL.
 *        Success shape: `{ "ok": true, "protocol_version": 2, "validation_issues": [...],
 *        "summary": { "total_validation_issues", "info_count", "warning_count",
 *        "error_count" } }`.
 *        Schema: `schemas/abi/validate_response.schema.json`
 *        Caller frees with FITS_free().
 *
 * @return FITS_OK on success, or a negative FitsStatus on failure.
 *
 * @see FITS_CORE_validate
 */
FitsStatus FITS_validate(FitsRepo *repo, const char *validate_request_json, char **validate_response_json);

/**
 * @brief Serialize the repository graph as JSON.
 *
 * @param repo Open repository handle from FITS_CORE_repo_open(). Must not be NULL.
 * @param output_graph_request_json UTF-8 JSON request body, or NULL to use defaults (`{}`).
 *        Optional fields:
 *        - `protocol_version` (integer, currently `1`)
 *        - `pretty_print` (boolean, default `false`)
 *        Schema: `schemas/abi/output_graph_request.schema.json`
 * @param output_graph_response_json Out pointer. On return, set to an allocated response
 *        document. Must not be NULL.
 *        Success shape: `{ "ok": true, "graph": <object> }` where `graph`
 *        is the repository graph encoded as JSON.
 *        Caller frees with FITS_free().
 *
 * @return FITS_OK on success, or a negative FitsStatus on failure.
 */
FitsStatus FITS_output_graph(FitsRepo *repo, const char *output_graph_request_json, char **output_graph_response_json);

/**
 * @brief Create a new node in the repository.
 *
 * @param repo Open repository handle from FITS_CORE_repo_open(). Must not be NULL.
 * @param new_node_request_json UTF-8 JSON request body. Must not be NULL.
 *        Required fields:
 *        - `id_prefix` (string): node type prefix registered in the registry.
 *        Optional fields:
 *        - `protocol_version` (integer, currently `1`)
 *        - `markdown` (boolean, default `false`)
 *        - `title` (string): initial title text; omitted or empty for no title.
 *        Schema: `schemas/abi/new_node_request.schema.json`
 * @param new_node_response_json Out pointer. On return, set to an allocated response
 *        document. Must not be NULL.
 *        Success shape: `{ "ok": true, "node_id": "<id>" }`.
 *        Schema: `schemas/abi/new_node_response.schema.json`
 *        Caller frees with FITS_free().
 *
 * @return FITS_OK on success, or a negative FitsStatus on failure.
 *
 * @see FITS_CORE_new_node
 */
FitsStatus FITS_new_node(FitsRepo *repo, const char *new_node_request_json, char **new_node_response_json);

/**
 * @brief Create a new link between two nodes.
 *
 * @param repo Open repository handle from FITS_CORE_repo_open(). Must not be NULL.
 * @param new_link_request_json UTF-8 JSON request body. Must not be NULL.
 *        Required fields:
 *        - `link_type` (string)
 *        - `in_id` (string): tail node id
 *        - `out_id` (string): head node id
 *        Optional field:
 *        - `protocol_version` (integer, currently `1`)
 *        Schema: `schemas/abi/new_link_request.schema.json`
 * @param new_link_response_json Out pointer. On return, set to an allocated response
 *        document. Must not be NULL.
 *        Success shape: `{ "ok": true }`.
 *        Caller frees with FITS_free().
 *
 * @return FITS_OK on success, or a negative FitsStatus on failure.
 *
 * @see FITS_CORE_new_link
 */
FitsStatus FITS_new_link(FitsRepo *repo, const char *new_link_request_json, char **new_link_response_json);

/**
 * @brief Remove a node or link from the repository.
 *
 * @param repo Open repository handle from FITS_CORE_repo_open(). Must not be NULL.
 * @param remove_request_json UTF-8 JSON request body. Must not be NULL.
 *        Required fields:
 *        - `object_id` (string): id of the node or link to remove.
 *        Optional field:
 *        - `protocol_version` (integer, currently `1`)
 *        Schema: `schemas/abi/remove_request.schema.json`
 * @param remove_response_json Out pointer. On return, set to an allocated response
 *        document. Must not be NULL.
 *        Success shape: `{ "ok": true }`.
 *        Caller frees with FITS_free().
 *
 * @return FITS_OK on success, or a negative FitsStatus on failure.
 *
 * @see FITS_CORE_remove_obj
 */
FitsStatus FITS_remove_obj(FitsRepo *repo, const char *remove_request_json, char **remove_response_json);

/**
 * @brief Initialize an empty directory as a fits repository.
 *
 * Creates registry layout, default links file, and related scaffolding under
 * the repository root passed to FITS_CORE_repo_open().
 *
 * @param repo Open repository handle from FITS_CORE_repo_open(). Must not be NULL.
 * @param init_request_json UTF-8 JSON request body, or NULL to use defaults (`{}`).
 *        Optional fields:
 *        - `protocol_version` (integer, currently `1`)
 *        - `no_interactive` (boolean, default `true`)
 *        - `init_git` (boolean, default `false`)
 *        - `edit_gitignore` (boolean, default `false`)
 *        Schema: `schemas/abi/init_request.schema.json`
 * @param init_response_json Out pointer. On return, set to an allocated response
 *        document. Must not be NULL.
 *        Success shape: `{ "ok": true }`.
 *        Caller frees with FITS_free().
 *
 * @return FITS_OK on success, or a negative FitsStatus on failure.
 *
 * @see FITS_CORE_repo_init
 */
FitsStatus FITS_init(FitsRepo *repo, const char *init_request_json, char **init_response_json);

/**
 * @brief Register a node type in the repository registry.
 *
 * @param repo Open repository handle from FITS_CORE_repo_open(). Must not be NULL.
 * @param register_node_type_request_json UTF-8 JSON request body. Must not be NULL.
 *        Required fields:
 *        - `type_name` (string)
 *        Optional fields:
 *        - `protocol_version` (integer, currently `1`)
 *        - `abstract` (boolean, default `false`)
 *        - `extends` (string): required when `abstract` is `false`
 *        - `create_folder` (boolean, default `false`)
 *        Schema: `schemas/abi/register_node_type_request.schema.json`
 * @param register_node_type_response_json Out pointer. On return, set to an allocated
 *        response document. Must not be NULL.
 *        Success shape: `{ "ok": true }`.
 *        Caller frees with FITS_free().
 *
 * @return FITS_OK on success, or a negative FitsStatus on failure.
 *
 * @see FITS_CORE_registry_register_node_type
 */
FitsStatus FITS_register_node_type(FitsRepo *repo, const char *register_node_type_request_json, char **register_node_type_response_json);

/**
 * @brief Register a link type in the repository registry.
 *
 * @param repo Open repository handle from FITS_CORE_repo_open(). Must not be NULL.
 * @param register_link_type_request_json UTF-8 JSON request body. Must not be NULL.
 *        Required fields:
 *        - `link_type` (string)
 *        - `in_type` (string): allowed tail node type
 *        - `out_type` (string): allowed head node type
 *        Optional fields:
 *        - `protocol_version` (integer, currently `1`)
 *        - `create_folder` (boolean, default `false`)
 *        Schema: `schemas/abi/register_link_type_request.schema.json`
 * @param register_link_type_response_json Out pointer. On return, set to an allocated
 *        response document. Must not be NULL.
 *        Success shape: `{ "ok": true }`.
 *        Caller frees with FITS_free().
 *
 * @return FITS_OK on success, or a negative FitsStatus on failure.
 *
 * @see FITS_CORE_registry_register_link_type
 */
FitsStatus FITS_register_link_type(FitsRepo *repo, const char *register_link_type_request_json, char **register_link_type_response_json);

/**
 * @defgroup abi_schemas JSON Schema accessors
 * @{
 * Each function returns the UTF-8 JSON Schema document for the corresponding
 * `schemas/abi/*.schema.json` file. Storage is static (process lifetime); do not
 * call FITS_free() on the returned pointer.
 */

/** @return Static JSON Schema for validate requests. */
const char *FITS_validate_request_schema(void);

/** @return Static JSON Schema for validate responses. */
const char *FITS_validate_response_schema(void);

/** @return Static JSON Schema for output_graph requests. */
const char *FITS_output_graph_request_schema(void);

/** @return Static JSON Schema for new_node requests. */
const char *FITS_new_node_request_schema(void);

/** @return Static JSON Schema for new_node responses. */
const char *FITS_new_node_response_schema(void);

/** @return Static JSON Schema for new_link requests. */
const char *FITS_new_link_request_schema(void);

/** @return Static JSON Schema for remove requests. */
const char *FITS_remove_request_schema(void);

/** @return Static JSON Schema for init requests. */
const char *FITS_init_request_schema(void);

/** @return Static JSON Schema for register_node_type requests. */
const char *FITS_register_node_type_request_schema(void);

/** @return Static JSON Schema for register_link_type requests. */
const char *FITS_register_link_type_request_schema(void);

/** @return Static JSON Schema for structured error responses. */
const char *FITS_error_response_schema(void);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* LIBFITS_H */
