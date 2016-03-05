#!/bin/bash

# Copyright 2016  ASLP (Author: zhangbinbin)
# Apache 2.0

stage=3
feat_dir=data_fbank
gmmdir=exp/tri2b
dir=exp/dnn_fbank_sync10
ali=${gmmdir}_ali
num_cv_utt=3484

echo "$0 $@"  # Print the command line for logging
[ -f cmd.sh ] && . ./cmd.sh;
[ -f path.sh ] && . ./path.sh; 
. parse_options.sh || exit 1;

set -euo pipefail

# Making features, this script will gen corresponding feat and dir
# eg data-fbank/train data-fbank/train_tr90 data-fbank/train_cv10 data-fbank/test
if [ $stage -le 0 ]; then
    echo "Extracting feats & Create tr cv set"
    aslp_scripts/make_feats.sh --feat-type "fbank" data/train $feat_dir
    # Split tr & cv
    utils/shuffle_list.pl $feat_dir/train/feats.scp > $feat_dir/train/random.scp
    head -n$num_cv_utt $feat_dir/train/random.scp | sort > $feat_dir/train/cv.scp
    total=$(cat $feat_dir/train/random.scp | wc -l)
    left=$[$total-$num_cv_utt]
    tail -n$left $feat_dir/train/random.scp | sort > $feat_dir/train/tr.scp
    utils/subset_data_dir.sh --utt-list $feat_dir/train/tr.scp \
        $feat_dir/train $feat_dir/train_tr
    utils/subset_data_dir.sh --utt-list $feat_dir/train/cv.scp \
        $feat_dir/train $feat_dir/train_cv
	aslp_scripts/make_feats.sh --feat-type "fbank" data/test $feat_dir
fi

# Prepare feature and alignment config file for nn training
# This script will make $dir/train.conf automaticlly
if [ $stage -le 1 ]; then
    echo "Preparing alignment and feats"
        #--delta_opts "--delta-order=2" \
    aslp_scripts/aslp_nnet/prepare_feats_ali.sh \
        --cmvn_opts "--norm-means=true --norm-vars=true" \
        --splice_opts "--left-context=5 --right-context=5" \
        $feat_dir/train_tr $feat_dir/train_cv data/lang $ali $ali $dir || exit 1;
fi

# Get feats_tr feats_cv labels_tr labels_cv 
[ ! -f $dir/train.conf ] && \
    echo "$dir/train.conf(config file for nn training): no such file" && exit 1 
source $dir/train.conf

# Prerain nnet(dnn, cnn, lstm)
if [ $stage -le 2 ]; then
    echo "Pretraining nnet"
    num_feat=$(feat-to-dim "$feats_tr" -) 
    num_tgt=$(hmm-info --print-args=false $ali/final.mdl | grep pdfs | awk '{ print $NF }')
    hid_dim=1024        # number of neurons per layer,
    hid_layers=4        # nr. of hidden layers (before sotfmax or bottleneck),
    echo $num_feat $num_tgt
cat > $dir/hidden.conf <<EOF
<NnetProto>
<AffineTransform> <InputDim> $hid_dim <OutputDim> $hid_dim <BiasMean> -2.000000 <BiasRange> 4.000000 <ParamStddev> 0.1
<Sigmoid> <InputDim> $hid_dim <OutputDim> $hid_dim 
</NnetProto>
EOF

# Init nnet.proto with 3 layers
cat > $dir/nnet.proto <<EOF
<NnetProto>
<AffineTransform> <InputDim> $num_feat <OutputDim> $hid_dim <BiasMean> -2.000000 <BiasRange> 4.000000 <ParamStddev> 0.1
<Sigmoid> <InputDim> $hid_dim <OutputDim> $hid_dim 
<AffineTransform> <InputDim> $hid_dim <OutputDim> $num_tgt <BiasMean> -2.000000 <BiasRange> 4.000000 <ParamStddev> 0.1
<Softmax> <InputDim> $num_tgt <OutputDim> $num_tgt
</NnetProto>
EOF
    #"$train_cmd" $dir/log/pretrain.log \
    aslp_scripts/aslp_nnet/pretrain.sh --train-tool "aslp-nnet-train-simple" \
        --learn-rate 0.008 \
        --momentum 0.0 \
        --minibatch_size 256 \
        --train-tool-opts "--report-period=60000" \
        --iters_per_epoch 2 \
        "$feats_tr" "$labels_tr" $hid_layers $dir
fi

# Train nnet(dnn, cnn, lstm)
if [ $stage -le 3 ]; then
    # Preprocessing for 2-card mpi-sync train
    cp $dir/train.conf $dir/train.conf.JOB
    sed -i -e 's:train.scp:train.scp.JOB:g' $dir/train.conf.JOB
    source $dir/train.conf.JOB
    train_scp=$dir/train.scp
    utils/split_scp.pl $train_scp $train_scp.0 $train_scp.1

    echo "Training nnet"
    [ ! -f $dir/nnet/pretrain.final.nnet ] && \
        echo "$dir/nnet/pretrain.final.nnet: no such file" && exit 1
    nnet_init=$dir/nnet/train.nnet.init
    [ -e $nnet_init ] && rm $nnet_init
    ln -s $(basename $dir/nnet/pretrain.final.nnet) $nnet_init
    #"$train_cmd" $dir/log/train.log \
    aslp_scripts/aslp_nnet/train_scheduler_mpi.sh \
        --train-tool "aslp-nnet-train-simple-mpi" \
        --cv-tool "aslp-nnet-train-simple" \
        --sync-period 10 \
        --learn-rate 0.008 \
        --momentum 0.0 \
        --minibatch_size 256 \
        --train-tool-opts "--report-period=60000" \
        $nnet_init "$feats_tr" "$feats_cv" "$labels_tr" "$labels_cv" $dir
fi

# Decoding 
if [ $stage -le 4 ]; then
    aslp_scripts/aslp_nnet/decode.sh --nj 2 --num-threads 12 \
        --cmd "$decode_cmd" --acwt 0.0666667 \
        $gmmdir/graph $feat_dir/test $dir/decode_test3000 || exit 1;
    aslp_scripts/score_basic.sh --cmd "$decode_cmd" $feat_dir/test \
        $gmmdir/graph $dir/decode_test3000 || exit 1;
fi

