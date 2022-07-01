# Train the model

WORKSPACE="${WORKSPACE:?"Export WORKSPACE env var to specify a directory for outputs."}"
OUT_DIR="${OUT_DIR:-"${WORKSPACE:-.}/train_artifacts"}"
DATABIN="${DATABIN:-"${WORKSPACE:-.}/wmt16_en_de/databin"}"

set -x

export MKL_THREADING_LAYER="${MKL_THREADING_LAYER:-GNU}"

USER_DIR=${USER_DIR:-"./user"}
FS_TRAIN="$USER_DIR/train.py"
FS_GENERATE="$USER_DIR/generate.py"

preprocess() {
    TEXT="${WORKSPACE}/wmt16_en_de"
    mkdir -p "$DATABIN"
    fairseq-preprocess \
        --source-lang en --target-lang de \
        --trainpref "$TEXT/train" \
        --validpref "$TEXT/valid" \
        --testpref  "$TEXT/test" \
        --destdir   "${DATABIN}" \
        --nwordssrc 32768 --nwordstgt 32768 \
        --joined-dictionary \
        --workers 20
}

[[ ! -s "${DATABIN}/preprocess.log" ]] && preprocess


# ARCH='transformer_vaswani_wmt_en_de_big'
# ARCH='transformer_ds_moe_vaswani_wmt_en_de_big'
# ARCH='transformer_ds_moe_tiny'
# ARCH='transformer_tiny'
ARCH=${ARCH:?"Export ARCH env var to specify an architecture name, e.g. 'transformer_ds_moe_tiny'."}

if [[ $ARCH == *ds_moe* ]]; then
    NUM_GPUS=${NUM_GPUS:-8}
    NUM_EXPERTS=${NUM_EXPERTS:-8}
    MOE_MODE=${MOE_MODE:-enc,dec}
    Config=(
        --task 'translation_deepspeed'
        --deepspeed_moe "$MOE_MODE"
            --ep-world-size $NUM_GPUS
            --num-experts   $NUM_EXPERTS
            --top-k 1
        --criterion 'model_and_base'
            --loss-weights '{"base_crit": 1, "experts_gate_loss": 10}'
            --base-criterion 'label_smoothed_cross_entropy'
            --base-criterion-config '{"label_smoothing": 0.1}'
    )
    RUN_NAME_default="moe_g${NUM_GPUS}_ep${NUM_GPUS}_ex${NUM_EXPERTS}_k1_${MOE_MODE//,/}"
else
    Config=(
        --task translation_deepspeed
        --criterion label_smoothed_cross_entropy
            --label-smoothing 0.1
    )
    RUN_NAME_default=baseline
fi

DONT_SAVE="${DONT_SAVE:+"--no-save"}"
RUN_NAME="${RUN_NAME:-$RUN_NAME_default}"

if [[ "$MNN_DEBUG" ]]; then
    UPDATE_FREQ=1
    MAX_TOKENS=512
    DONT_SAVE=''
    SAVE_INTERVAL_UPDATES=2
fi

export NCCL_IB_DISABLE=1
export NCCL_SOCKET_IFNAME=eth0

train() {
    SaveDir="${OUT_DIR?}/checkpoints/${ARCH}-${RUN_NAME}"
    mkdir -p $SaveDir
        # --distributed-no-spawn \

    python "$FS_TRAIN" \
        "${DATABIN?}" \
        --seed 43821 \
        --user-dir "${USER_DIR?}" \
        --ddp-backend=legacy_ddp --fp16 \
        --arch $ARCH \
        -s 'de' -t 'en' \
        "${Config[@]}" \
        --reset-optimizer \
        --optimizer adam \
            --adam-betas '(0.9, 0.98)' \
            --clip-norm 0.0 \
        --lr 5e-4 \
            --dropout 0.3 \
            --weight-decay 0.0001 \
            --lr-scheduler inverse_sqrt \
            --warmup-updates 4000 \
        --max-update 300000 \
        --max-tokens "${MAX_TOKENS:-8192}" \
            --update-freq "${UPDATE_FREQ:-16}" \
        --validate-interval-updates 20 \
        --batch-size-valid "${BATCH_SIZE_VALID:-16}" \
        --eval-bleu \
            --scoring sacrebleu \
            --eval-bleu-args '{"beam": 2, "max_len_a": 1.2, "max_len_b": 10}' \
            --eval-bleu-detok moses \
            --eval-bleu-remove-bpe \
            --eval-bleu-print-samples \
        --best-checkpoint-metric bleu --maximize-best-checkpoint-metric \
            --keep-last-epochs 4 \
            --save-interval-updates "${SAVE_INTERVAL_UPDATES:-100}" \
            --keep-interval-updates 4 \
            --save-dir "${SaveDir}" \
            ${DONT_SAVE} \
            --tensorboard-logdir "$OUT_DIR/tb/${ARCH}-${RUN_NAME}"
}

generate() {
    export max_split_size_mb=1024
    SaveDir="${OUT_DIR?}/tests/${ARCH}-${RUN_NAME}"
    LatestCheckpoint="${OUT_DIR?}/checkpoints/${ARCH}-${RUN_NAME}/checkpoint_last.pt"
    mkdir -p "$SaveDir"
    # ipython "$FS_GENERATE" \
    # ipython \
    # ipython -m pdb \
    # ipython -m torch.distributed.launch \
    # torchrun \
    # --nproc_per_node=${NUM_GPUS} \
    # --node_rank=${NODE_RANK:-0} \
    # --nnodes=${NODE_COUNT:-1} \
    # --master_addr=${MASTER_ADDR:-127.0.0.1} \
    # --master_port=${MASTER_PORT:-54321} \
    # -- \
    # ipython \
        # --beam 2 --lenpen 0.6 --remove-bpe \
    deepspeed \
    "$FS_GENERATE" \
        "${DATABIN?}" \
        --seed 43821 \
        --user-dir "$USER_DIR" \
        --ddp-backend=legacy_ddp --fp16 \
        --arch $ARCH \
        -s 'de' -t 'en' \
        "${Config[@]}" \
        --path "${LatestCheckpoint}" \
        --scoring sacrebleu \
            --eval-bleu-args '{"beam": 2, "max_len_a": 1.2, "max_len_b": 10}' \
            --eval-bleu-detok moses \
            --eval-bleu-remove-bpe \
        --save-dir "${SaveDir}" \
        --max-tokens "${MAX_GEN_TOKENS:-1024}" \
        --tensorboard-logdir "${OUT_DIR?}/tb/${ARCH}-${RUN_NAME}"
    # --max-tokens-valid "${MAX_GEN_TOKENS:-512}" \
    # | tee "${SaveDir}/gen.out"
}

Func="${1:-train}"
if [[ "$Func" == 'train' ]]; then
    train
elif [[ "$Func" == 'test' ]]; then
    generate
fi

