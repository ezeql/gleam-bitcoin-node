#include <erl_nif.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "bitcoinkernel.h"

static ERL_NIF_TERM atom_ok, atom_error, atom_true, atom_false, atom_bad_tx,
    atom_invalid_flags, atom_spent_outputs_required, atom_unknown_status;

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)priv;
    (void)info;
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_true = enif_make_atom(env, "true");
    atom_false = enif_make_atom(env, "false");
    atom_bad_tx = enif_make_atom(env, "bad_tx");
    atom_invalid_flags = enif_make_atom(env, "invalid_flags_combination");
    atom_spent_outputs_required = enif_make_atom(env, "spent_outputs_required");
    atom_unknown_status = enif_make_atom(env, "unknown_status");
    btck_logging_disable();
    return 0;
}

static ERL_NIF_TERM status_term(btck_ScriptVerifyStatus status) {
    switch (status) {
    case btck_ScriptVerifyStatus_ERROR_INVALID_FLAGS_COMBINATION:
        return atom_invalid_flags;
    case btck_ScriptVerifyStatus_ERROR_SPENT_OUTPUTS_REQUIRED:
        return atom_spent_outputs_required;
    default:
        return atom_unknown_status;
    }
}

/* verify(Tx, [{Script, Amount}], Flags) -> {ok, true|false} | {error, atom} */
static ERL_NIF_TERM verify(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary txbin;
    unsigned int nspent;
    unsigned int flags;

    if (!enif_inspect_binary(env, argv[0], &txbin)) return enif_make_badarg(env);
    if (!enif_get_list_length(env, argv[1], &nspent)) return enif_make_badarg(env);
    if (!enif_get_uint(env, argv[2], &flags)) return enif_make_badarg(env);
    if ((flags & ~((unsigned int)btck_ScriptVerificationFlags_ALL)) != 0) return enif_make_badarg(env);

    btck_Transaction *tx = btck_transaction_create(txbin.data, txbin.size);
    if (tx == NULL) return enif_make_tuple2(env, atom_error, atom_bad_tx);

    size_t nin = btck_transaction_count_inputs(tx);
    if ((size_t)nspent != nin) {
        btck_transaction_destroy(tx);
        return enif_make_badarg(env);
    }

    ERL_NIF_TERM result = 0;
    btck_ScriptPubkey **spks = NULL;
    btck_TransactionOutput **outs = NULL;
    int64_t *amounts = NULL;
    btck_PrecomputedTransactionData *txdata = NULL;
    size_t built = 0;

    if (nin > 0) {
        spks = enif_alloc(sizeof(*spks) * nin);
        outs = enif_alloc(sizeof(*outs) * nin);
        amounts = enif_alloc(sizeof(*amounts) * nin);
        if (!spks || !outs || !amounts) {
            result = enif_raise_exception(env, enif_make_atom(env, "enomem"));
            goto cleanup;
        }
    }

    ERL_NIF_TERM list = argv[1], head;
    for (size_t i = 0; i < nin; i++) {
        const ERL_NIF_TERM *tup;
        int arity;
        ErlNifBinary spk;
        ErlNifSInt64 amount;
        if (!enif_get_list_cell(env, list, &head, &list) ||
            !enif_get_tuple(env, head, &arity, &tup) || arity != 2 ||
            !enif_inspect_binary(env, tup[0], &spk) ||
            !enif_get_int64(env, tup[1], &amount)) {
            result = enif_make_badarg(env);
            goto cleanup;
        }
        spks[i] = btck_script_pubkey_create(spk.data, spk.size);
        if (spks[i] == NULL) {
            result = enif_raise_exception(env, enif_make_atom(env, "kernel_alloc"));
            goto cleanup;
        }
        outs[i] = btck_transaction_output_create(spks[i], (int64_t)amount);
        if (outs[i] == NULL) {
            btck_script_pubkey_destroy(spks[i]);
            result = enif_raise_exception(env, enif_make_atom(env, "kernel_alloc"));
            goto cleanup;
        }
        amounts[i] = (int64_t)amount;
        built++;
    }

    txdata = btck_precomputed_transaction_data_create(
        tx, nin > 0 ? (const btck_TransactionOutput **)outs : NULL, nin);
    if (txdata == NULL) {
        result = enif_raise_exception(env, enif_make_atom(env, "kernel_txdata"));
        goto cleanup;
    }

    {
        int all_ok = 1;
        for (size_t i = 0; i < nin; i++) {
            btck_ScriptVerifyStatus status = btck_ScriptVerifyStatus_OK;
            int ok = btck_script_pubkey_verify(
                spks[i], amounts[i], tx, txdata, (unsigned int)i,
                (btck_ScriptVerificationFlags)flags, &status);
            if (status != btck_ScriptVerifyStatus_OK) {
                result = enif_make_tuple2(env, atom_error, status_term(status));
                goto cleanup;
            }
            if (ok != 1) all_ok = 0;
        }
        result = enif_make_tuple2(env, atom_ok, all_ok ? atom_true : atom_false);
    }

cleanup:
    if (txdata) btck_precomputed_transaction_data_destroy(txdata);
    for (size_t i = 0; i < built; i++) {
        btck_transaction_output_destroy(outs[i]);
        btck_script_pubkey_destroy(spks[i]);
    }
    if (spks) enif_free(spks);
    if (outs) enif_free(outs);
    if (amounts) enif_free(amounts);
    btck_transaction_destroy(tx);
    return result;
}

static ErlNifFunc nifs[] = {
    {"verify_nif", 3, verify, 0},
};

ERL_NIF_INIT(gleam_bitcoin_node_kernel, nifs, load, NULL, NULL, NULL)
