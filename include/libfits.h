#ifndef LIBFITS_H
#define LIBFITS_H

#include "fits_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * JSON layer: per-operation request/response bodies (UTF-8 JSON).
 * response_json is always allocated on success or structured failure;
 * free with fits_free(). See schemas/abi/ and docs/abi.md.
 */

FitsStatus libfits_validate_json(FitsRepo *repo, const char *request_json, char **response_json);
FitsStatus libfits_output_graph_json(FitsRepo *repo, const char *request_json, char **response_json);
FitsStatus libfits_new_node_json(FitsRepo *repo, const char *request_json, char **response_json);
FitsStatus libfits_new_link_json(FitsRepo *repo, const char *request_json, char **response_json);
FitsStatus libfits_remove_json(FitsRepo *repo, const char *request_json, char **response_json);
FitsStatus libfits_init_json(FitsRepo *repo, const char *request_json, char **response_json);
FitsStatus libfits_register_node_type_json(FitsRepo *repo, const char *request_json, char **response_json);
FitsStatus libfits_register_link_type_json(FitsRepo *repo, const char *request_json, char **response_json);

#ifdef __cplusplus
}
#endif

#endif /* LIBFITS_H */
