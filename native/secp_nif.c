#include <erl_nif.h>
#include <string.h>
#include <sys/random.h>

typedef struct secp256k1_context_struct secp256k1_context;

typedef int (*secp256k1_ellswift_xdh_hash_function)(
    unsigned char *output,
    const unsigned char *x32,
    const unsigned char *ell_a64,
    const unsigned char *ell_b64,
    void *data);

#define SECP256K1_CONTEXT_NONE 1

secp256k1_context *secp256k1_context_create(unsigned int flags);
void secp256k1_context_destroy(secp256k1_context *ctx);
int secp256k1_context_randomize(secp256k1_context *ctx, const unsigned char *seed32);
int secp256k1_ec_seckey_verify(const secp256k1_context *ctx, const unsigned char *seckey);
int secp256k1_ellswift_create(
    const secp256k1_context *ctx,
    unsigned char *ell64,
    const unsigned char *seckey32,
    const unsigned char *auxrnd32);
int secp256k1_ellswift_xdh(
    const secp256k1_context *ctx,
    unsigned char *output,
    const unsigned char *ell_a64,
    const unsigned char *ell_b64,
    const unsigned char *seckey32,
    int party,
    secp256k1_ellswift_xdh_hash_function hashfp,
    void *data);

extern const secp256k1_ellswift_xdh_hash_function secp256k1_ellswift_xdh_hash_function_bip324;

static secp256k1_context *ctx = NULL;
static ERL_NIF_TERM atom_ok, atom_error;

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    unsigned char seed[32];
    (void)priv;
    (void)info;
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
    if (ctx == NULL) return 1;
    if (getrandom(seed, sizeof(seed), 0) != (ssize_t)sizeof(seed)) return 1;
    if (!secp256k1_context_randomize(ctx, seed)) return 1;
    memset(seed, 0, sizeof(seed));
    return 0;
}

static void unload(ErlNifEnv *env, void *priv) {
    (void)env;
    (void)priv;
    if (ctx) secp256k1_context_destroy(ctx);
    ctx = NULL;
}

static int exact(ErlNifEnv *env, ERL_NIF_TERM t, size_t len, ErlNifBinary *out) {
    return enif_inspect_binary(env, t, out) && out->size == len;
}

static ERL_NIF_TERM create(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary sk, aux;
    ERL_NIF_TERM out;
    unsigned char *ell;
    if (argc != 2 || !exact(env, argv[0], 32, &sk) || !exact(env, argv[1], 32, &aux))
        return enif_make_badarg(env);
    if (!secp256k1_ec_seckey_verify(ctx, sk.data)) return atom_error;
    ell = enif_make_new_binary(env, 64, &out);
    if (!secp256k1_ellswift_create(ctx, ell, sk.data, aux.data)) return atom_error;
    return enif_make_tuple2(env, atom_ok, out);
}

static ERL_NIF_TERM xdh(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary a, b, sk;
    int party;
    ERL_NIF_TERM out;
    unsigned char *secret;
    if (argc != 4 || !exact(env, argv[0], 64, &a) || !exact(env, argv[1], 64, &b) ||
        !exact(env, argv[2], 32, &sk) || !enif_get_int(env, argv[3], &party) ||
        (party != 0 && party != 1))
        return enif_make_badarg(env);
    if (!secp256k1_ec_seckey_verify(ctx, sk.data)) return atom_error;
    secret = enif_make_new_binary(env, 32, &out);
    if (!secp256k1_ellswift_xdh(ctx, secret, a.data, b.data, sk.data, party,
                                secp256k1_ellswift_xdh_hash_function_bip324, NULL))
        return atom_error;
    return enif_make_tuple2(env, atom_ok, out);
}

static ErlNifFunc nifs[] = {
    {"create_nif", 2, create, 0},
    {"xdh_nif", 4, xdh, 0},
};

ERL_NIF_INIT(gleam_bitcoin_node_secp, nifs, load, NULL, NULL, unload)
