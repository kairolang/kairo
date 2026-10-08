; ModuleID = '<injected>'
source_filename = "<injected>"
target datalayout = "e-m:e-p:32:32-Fi8-i64:64-v128:64:128-a:0:32-n32-S64"
target triple = "thumbv6m-unknown-none-eabi"

%"struct.countdown::Reg" = type { i32 }
%"struct.countdown::Pins" = type { i32 }
%"class.countdown::Display" = type { i32, i32 }
%"class.countdown::RgbLed" = type { i32 }
%"class.countdown::Countdown" = type { i32, i32, i32, i32 }

@_ZN9countdown10RESETS_CLRE = local_unnamed_addr constant %"struct.countdown::Reg" { i32 1073803264 }, align 4
@_ZN9countdown10RESET_DONEE = local_unnamed_addr constant %"struct.countdown::Reg" { i32 1073790984 }, align 4
@_ZN9countdown9XOSC_CTRLE = local_unnamed_addr constant %"struct.countdown::Reg" { i32 1073889280 }, align 4
@_ZN9countdown11XOSC_STATUSE = local_unnamed_addr constant %"struct.countdown::Reg" { i32 1073889284 }, align 4
@_ZN9countdown12XOSC_STARTUPE = local_unnamed_addr constant %"struct.countdown::Reg" { i32 1073889292 }, align 4
@_ZN9countdown12CLK_REF_CTRLE = local_unnamed_addr constant %"struct.countdown::Reg" { i32 1073774640 }, align 4
@_ZN9countdown16CLK_REF_SELECTEDE = local_unnamed_addr constant %"struct.countdown::Reg" { i32 1073774648 }, align 4
@_ZN9countdown13WATCHDOG_TICKE = local_unnamed_addr constant %"struct.countdown::Reg" { i32 1074102316 }, align 4
@_ZN9countdown10TIMER_RAWLE = local_unnamed_addr constant %"struct.countdown::Reg" { i32 1074085928 }, align 4
@_ZN9countdown11SIO_OUT_SETE = local_unnamed_addr constant %"struct.countdown::Reg" { i32 -805306348 }, align 4
@_ZN9countdown11SIO_OUT_CLRE = local_unnamed_addr constant %"struct.countdown::Reg" { i32 -805306344 }, align 4
@_ZN9countdown10SIO_OE_SETE = local_unnamed_addr constant %"struct.countdown::Reg" { i32 -805306332 }, align 4
@_ZN9countdown10RESET_BITSE = local_unnamed_addr constant i32 2097440, align 4
@_ZN9countdown11FUNCSEL_SIOE = local_unnamed_addr constant i32 5, align 4
@_ZN9countdown6MUX_USE = local_unnamed_addr constant i32 2000, align 4
@_ZN9countdown9SECOND_USE = local_unnamed_addr constant i32 1000000, align 4
@__const._ZN9countdown4fontEj.table = private unnamed_addr constant [10 x i32] [i32 63, i32 6, i32 91, i32 79, i32 102, i32 109, i32 125, i32 7, i32 127, i32 111], align 4

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local void @_ZN9countdown15__kairo_ext_Reg5writeEPKNS_3RegEj(ptr noundef readonly captures(none) %self, i32 noundef %v) local_unnamed_addr #0 align 2 {
entry:
  %0 = load i32, ptr %self, align 4, !tbaa !7
  %1 = inttoptr i32 %0 to ptr
  store volatile i32 %v, ptr %1, align 4, !tbaa !3
  ret void
}

; Function Attrs: minsize mustprogress nofree norecurse nounwind optsize willreturn memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local noundef i32 @_ZN9countdown15__kairo_ext_Reg4readEPKNS_3RegE(ptr noundef readonly captures(none) %self) local_unnamed_addr #1 align 2 {
entry:
  %0 = load i32, ptr %self, align 4, !tbaa !7
  %1 = inttoptr i32 %0 to ptr
  %2 = load volatile i32, ptr %1, align 4, !tbaa !3
  ret i32 %2
}

; Function Attrs: minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(none)
define dso_local range(i32 1073823748, 1073823741) i32 @_ZN9countdown9gpio_ctrlEj(i32 noundef %pin) local_unnamed_addr #2 {
entry:
  %mul = shl i32 %pin, 3
  %add = add i32 %mul, 1073823748
  ret i32 %add
}

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local void @_ZN9countdown10clock_initEv() local_unnamed_addr #0 {
entry:
  store volatile i32 2720, ptr inttoptr (i32 1073889280 to ptr), align 16384, !tbaa !3
  store volatile i32 47, ptr inttoptr (i32 1073889292 to ptr), align 4, !tbaa !3
  store volatile i32 16431776, ptr inttoptr (i32 1073889280 to ptr), align 16384, !tbaa !3
  br label %while.cond

while.cond:                                       ; preds = %while.cond, %entry
  %0 = load volatile i32, ptr inttoptr (i32 1073889284 to ptr), align 4, !tbaa !3
  %cmp = icmp sgt i32 %0, -1
  br i1 %cmp, label %while.cond, label %while.end

while.end:                                        ; preds = %while.cond
  store volatile i32 2, ptr inttoptr (i32 1073774640 to ptr), align 16, !tbaa !3
  br label %while.cond1

while.cond1:                                      ; preds = %while.cond1, %while.end
  %1 = load volatile i32, ptr inttoptr (i32 1073774648 to ptr), align 8, !tbaa !3
  %and3 = and i32 %1, 4
  %cmp4 = icmp eq i32 %and3, 0
  br i1 %cmp4, label %while.cond1, label %while.end6

while.end6:                                       ; preds = %while.cond1
  store volatile i32 524, ptr inttoptr (i32 1074102316 to ptr), align 4, !tbaa !3
  ret void
}

; Function Attrs: minsize mustprogress nofree norecurse nounwind optsize willreturn memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local noundef i32 @_ZN9countdown6now_usEv() local_unnamed_addr #1 {
entry:
  %0 = load volatile i32, ptr inttoptr (i32 1074085928 to ptr), align 8, !tbaa !3
  ret i32 %0
}

; Function Attrs: minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(none)
define dso_local i32 @_ZN9countdown16__kairo_ext_Pins5rangeEjj(i32 noundef %first, i32 noundef %count) local_unnamed_addr #2 align 2 {
entry:
  %notmask = shl nsw i32 -1, %count
  %sub = xor i32 %notmask, -1
  %shl1 = shl i32 %sub, %first
  ret i32 %shl1
}

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local void @_ZN9countdown16__kairo_ext_Pins4highEPKNS_4PinsE(ptr noundef readonly captures(none) %self) local_unnamed_addr #0 align 2 {
entry:
  %0 = load i32, ptr %self, align 4, !tbaa !9
  store volatile i32 %0, ptr inttoptr (i32 -805306348 to ptr), align 4, !tbaa !3
  ret void
}

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local void @_ZN9countdown16__kairo_ext_Pins3lowEPKNS_4PinsE(ptr noundef readonly captures(none) %self) local_unnamed_addr #0 align 2 {
entry:
  %0 = load i32, ptr %self, align 4, !tbaa !9
  store volatile i32 %0, ptr inttoptr (i32 -805306344 to ptr), align 8, !tbaa !3
  ret void
}

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local void @_ZN9countdown16__kairo_ext_Pins12make_outputsEPKNS_4PinsE(ptr noundef readonly captures(none) %self) local_unnamed_addr #0 align 2 {
entry:
  br label %for.cond

for.cond:                                         ; preds = %for.inc, %entry
  %p.0 = phi i32 [ 0, %entry ], [ %inc, %for.inc ]
  %exitcond.not = icmp eq i32 %p.0, 30
  %0 = load i32, ptr %self, align 4, !tbaa !9
  br i1 %exitcond.not, label %for.cond.cleanup, label %for.body

for.cond.cleanup:                                 ; preds = %for.cond
  store volatile i32 %0, ptr inttoptr (i32 -805306332 to ptr), align 4, !tbaa !3
  ret void

for.body:                                         ; preds = %for.cond
  %1 = shl nuw nsw i32 1, %p.0
  %2 = and i32 %0, %1
  %cmp1.not = icmp eq i32 %2, 0
  br i1 %cmp1.not, label %for.inc, label %if.then

if.then:                                          ; preds = %for.body
  %mul.i = shl nuw nsw i32 %p.0, 3
  %add.i = or disjoint i32 %mul.i, 1073823748
  %3 = inttoptr i32 %add.i to ptr
  store volatile i32 5, ptr %3, align 4, !tbaa !3
  br label %for.inc

for.inc:                                          ; preds = %for.body, %if.then
  %inc = add nuw nsw i32 %p.0, 1
  br label %for.cond
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #3

; Function Attrs: minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(none)
define dso_local noundef i32 @_ZN9countdown4fontEj(i32 noundef %n) local_unnamed_addr #2 {
entry:
  %arrayidx = getelementptr inbounds nuw i32, ptr @__const._ZN9countdown4fontEj.table, i32 %n
  %0 = load i32, ptr %arrayidx, align 4, !tbaa !3
  ret i32 %0
}

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local noundef nonnull ptr @_ZN9countdown7DisplayC2Ejj(ptr noundef nonnull returned align 4 captures(ret: address, provenance) dereferenceable(8) initializes((0, 8)) %this, i32 noundef %seg_first, i32 noundef %dig_first) unnamed_addr #0 align 2 {
entry:
  %ref.tmp = alloca %"struct.countdown::Pins", align 4
  %ref.tmp5 = alloca %"struct.countdown::Pins", align 4
  store i32 %seg_first, ptr %this, align 4, !tbaa !11
  %dig_first3 = getelementptr inbounds nuw i8, ptr %this, i32 4
  store i32 %dig_first, ptr %dig_first3, align 4, !tbaa !13
  %shl1.i.i.i = shl i32 255, %seg_first
  store volatile i32 %shl1.i.i.i, ptr inttoptr (i32 -805306348 to ptr), align 4, !tbaa !3
  %0 = load i32, ptr %dig_first3, align 4, !tbaa !13
  %shl1.i.i7.i = shl i32 15, %0
  store volatile i32 %shl1.i.i7.i, ptr inttoptr (i32 -805306344 to ptr), align 8, !tbaa !3
  call void @llvm.lifetime.start.p0(ptr nonnull %ref.tmp) #8
  %1 = load i32, ptr %this, align 4, !tbaa !11
  %shl1.i.i = shl i32 255, %1
  store i32 %shl1.i.i, ptr %ref.tmp, align 4
  call void @_ZN9countdown16__kairo_ext_Pins12make_outputsEPKNS_4PinsE(ptr noundef nonnull %ref.tmp) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %ref.tmp) #8
  call void @llvm.lifetime.start.p0(ptr nonnull %ref.tmp5) #8
  %2 = load i32, ptr %dig_first3, align 4, !tbaa !13
  %shl1.i.i9 = shl i32 15, %2
  store i32 %shl1.i.i9, ptr %ref.tmp5, align 4
  call void @_ZN9countdown16__kairo_ext_Pins12make_outputsEPKNS_4PinsE(ptr noundef nonnull %ref.tmp5) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %ref.tmp5) #8
  ret ptr %this
}

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local void @_ZNK9countdown7Display3offEv(ptr noundef nonnull readonly align 4 captures(none) dereferenceable(8) %this) local_unnamed_addr #0 align 2 {
entry:
  %0 = load i32, ptr %this, align 4, !tbaa !11
  %shl1.i.i = shl i32 255, %0
  store volatile i32 %shl1.i.i, ptr inttoptr (i32 -805306348 to ptr), align 4, !tbaa !3
  %dig_first.i = getelementptr inbounds nuw i8, ptr %this, i32 4
  %1 = load i32, ptr %dig_first.i, align 4, !tbaa !13
  %shl1.i.i7 = shl i32 15, %1
  store volatile i32 %shl1.i.i7, ptr inttoptr (i32 -805306344 to ptr), align 8, !tbaa !3
  ret void
}

; Function Attrs: minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(argmem: read)
define dso_local i32 @_ZNK9countdown7Display8segmentsEv(ptr noundef nonnull readonly align 4 captures(none) dereferenceable(8) %this) local_unnamed_addr #4 align 2 {
entry:
  %0 = load i32, ptr %this, align 4, !tbaa !11
  %shl1.i = shl i32 255, %0
  ret i32 %shl1.i
}

; Function Attrs: minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(argmem: read)
define dso_local i32 @_ZNK9countdown7Display6digitsEv(ptr noundef nonnull readonly align 4 captures(none) dereferenceable(8) %this) local_unnamed_addr #4 align 2 {
entry:
  %dig_first = getelementptr inbounds nuw i8, ptr %this, i32 4
  %0 = load i32, ptr %dig_first, align 4, !tbaa !13
  %shl1.i = shl i32 15, %0
  ret i32 %shl1.i
}

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local noundef nonnull ptr @_ZN9countdown7DisplayC1Ejj(ptr noundef nonnull returned align 4 captures(ret: address, provenance) dereferenceable(8) initializes((0, 8)) %this, i32 noundef %seg_first, i32 noundef %dig_first) unnamed_addr #0 align 2 {
entry:
  %call = tail call noundef ptr @_ZN9countdown7DisplayC2Ejj(ptr noundef nonnull align 4 dereferenceable(8) %this, i32 noundef %seg_first, i32 noundef %dig_first) #9
  ret ptr %this
}

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local void @_ZNK9countdown7Display4showEjj(ptr noundef nonnull readonly align 4 captures(none) dereferenceable(8) %this, i32 noundef %pattern, i32 noundef %d) local_unnamed_addr #0 align 2 {
entry:
  %0 = load i32, ptr %this, align 4, !tbaa !11
  %shl1.i.i.i = shl i32 255, %0
  store volatile i32 %shl1.i.i.i, ptr inttoptr (i32 -805306348 to ptr), align 4, !tbaa !3
  %dig_first.i.i = getelementptr inbounds nuw i8, ptr %this, i32 4
  %1 = load i32, ptr %dig_first.i.i, align 4, !tbaa !13
  %shl1.i.i7.i = shl i32 15, %1
  store volatile i32 %shl1.i.i7.i, ptr inttoptr (i32 -805306344 to ptr), align 8, !tbaa !3
  %2 = load i32, ptr %this, align 4, !tbaa !11
  %shl = shl i32 %pattern, %2
  %3 = load i32, ptr %dig_first.i.i, align 4, !tbaa !13
  %add = add i32 %3, %d
  %shl3 = shl nuw i32 1, %add
  store volatile i32 %shl, ptr inttoptr (i32 -805306344 to ptr), align 8, !tbaa !3
  store volatile i32 %shl3, ptr inttoptr (i32 -805306348 to ptr), align 4, !tbaa !3
  ret void
}

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local noundef nonnull ptr @_ZN9countdown6RgbLedC2Ej(ptr noundef nonnull returned align 4 captures(ret: address, provenance) dereferenceable(4) initializes((0, 4)) %this, i32 noundef %first) unnamed_addr #0 align 2 {
entry:
  %ref.tmp = alloca %"struct.countdown::Pins", align 4
  store i32 %first, ptr %this, align 4, !tbaa !14
  %shl1.i.i.i = shl i32 7, %first
  store volatile i32 %shl1.i.i.i, ptr inttoptr (i32 -805306344 to ptr), align 8, !tbaa !3
  call void @llvm.lifetime.start.p0(ptr nonnull %ref.tmp) #8
  %0 = load i32, ptr %this, align 4, !tbaa !14
  %shl1.i.i = shl i32 7, %0
  store i32 %shl1.i.i, ptr %ref.tmp, align 4
  call void @_ZN9countdown16__kairo_ext_Pins12make_outputsEPKNS_4PinsE(ptr noundef nonnull %ref.tmp) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %ref.tmp) #8
  ret ptr %this
}

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local void @_ZNK9countdown6RgbLed3offEv(ptr noundef nonnull readonly align 4 captures(none) dereferenceable(4) %this) local_unnamed_addr #0 align 2 {
entry:
  %0 = load i32, ptr %this, align 4, !tbaa !14
  %shl1.i.i = shl i32 7, %0
  store volatile i32 %shl1.i.i, ptr inttoptr (i32 -805306344 to ptr), align 8, !tbaa !3
  ret void
}

; Function Attrs: minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(argmem: read)
define dso_local i32 @_ZNK9countdown6RgbLed4pinsEv(ptr noundef nonnull readonly align 4 captures(none) dereferenceable(4) %this) local_unnamed_addr #4 align 2 {
entry:
  %0 = load i32, ptr %this, align 4, !tbaa !14
  %shl1.i = shl i32 7, %0
  ret i32 %shl1.i
}

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local noundef nonnull ptr @_ZN9countdown6RgbLedC1Ej(ptr noundef nonnull returned align 4 captures(ret: address, provenance) dereferenceable(4) initializes((0, 4)) %this, i32 noundef %first) unnamed_addr #0 align 2 {
entry:
  %call = tail call noundef ptr @_ZN9countdown6RgbLedC2Ej(ptr noundef nonnull align 4 dereferenceable(4) %this, i32 noundef %first) #9
  ret ptr %this
}

; Function Attrs: minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local void @_ZNK9countdown6RgbLed3setENS_5ColorE(ptr noundef nonnull readonly align 4 captures(none) dereferenceable(4) %this, i32 noundef %c) local_unnamed_addr #0 align 2 {
entry:
  %0 = load i32, ptr %this, align 4, !tbaa !14
  %shl1.i.i.i = shl i32 7, %0
  store volatile i32 %shl1.i.i.i, ptr inttoptr (i32 -805306344 to ptr), align 8, !tbaa !3
  %1 = load i32, ptr %this, align 4, !tbaa !14
  %add = add i32 %1, %c
  %shl = shl nuw i32 1, %add
  store volatile i32 %shl, ptr inttoptr (i32 -805306348 to ptr), align 4, !tbaa !3
  ret void
}

; Function Attrs: minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(argmem: write)
define dso_local noundef nonnull ptr @_ZN9countdown9CountdownC2Ejjj(ptr noundef nonnull returned writeonly align 4 captures(ret: address, provenance) dereferenceable(16) initializes((0, 16)) %this, i32 noundef %minutes, i32 noundef %seconds_tens, i32 noundef %seconds_ones) unnamed_addr #5 align 2 {
entry:
  store i32 0, ptr %this, align 4, !tbaa !16
  %m1 = getelementptr inbounds nuw i8, ptr %this, i32 4
  store i32 %minutes, ptr %m1, align 4, !tbaa !18
  %s10 = getelementptr inbounds nuw i8, ptr %this, i32 8
  store i32 %seconds_tens, ptr %s10, align 4, !tbaa !19
  %s1 = getelementptr inbounds nuw i8, ptr %this, i32 12
  store i32 %seconds_ones, ptr %s1, align 4, !tbaa !20
  ret ptr %this
}

; Function Attrs: minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(argmem: write)
define dso_local noundef nonnull ptr @_ZN9countdown9CountdownC1Ejjj(ptr noundef nonnull returned writeonly align 4 captures(ret: address, provenance) dereferenceable(16) initializes((0, 16)) %this, i32 noundef %minutes, i32 noundef %seconds_tens, i32 noundef %seconds_ones) unnamed_addr #5 align 2 {
entry:
  store i32 0, ptr %this, align 4, !tbaa !16
  %m1.i = getelementptr inbounds nuw i8, ptr %this, i32 4
  store i32 %minutes, ptr %m1.i, align 4, !tbaa !18
  %s10.i = getelementptr inbounds nuw i8, ptr %this, i32 8
  store i32 %seconds_tens, ptr %s10.i, align 4, !tbaa !19
  %s1.i = getelementptr inbounds nuw i8, ptr %this, i32 12
  store i32 %seconds_ones, ptr %s1.i, align 4, !tbaa !20
  ret ptr %this
}

; Function Attrs: minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(argmem: read)
define dso_local noundef zeroext i1 @_ZNK9countdown9Countdown7is_zeroEv(ptr noundef nonnull readonly align 4 captures(none) dereferenceable(16) %this) local_unnamed_addr #4 align 2 {
entry:
  %0 = load i32, ptr %this, align 4, !tbaa !16
  %cmp = icmp eq i32 %0, 0
  %m1 = getelementptr inbounds nuw i8, ptr %this, i32 4
  %1 = load i32, ptr %m1, align 4
  %cmp2 = icmp eq i32 %1, 0
  %or.cond = select i1 %cmp, i1 %cmp2, i1 false
  %s10 = getelementptr inbounds nuw i8, ptr %this, i32 8
  %2 = load i32, ptr %s10, align 4
  %cmp4 = icmp eq i32 %2, 0
  %or.cond6 = select i1 %or.cond, i1 %cmp4, i1 false
  br i1 %or.cond6, label %land.rhs, label %land.end

land.rhs:                                         ; preds = %entry
  %s1 = getelementptr inbounds nuw i8, ptr %this, i32 12
  %3 = load i32, ptr %s1, align 4, !tbaa !20
  %cmp5 = icmp eq i32 %3, 0
  br label %land.end

land.end:                                         ; preds = %land.rhs, %entry
  %4 = phi i1 [ false, %entry ], [ %cmp5, %land.rhs ]
  ret i1 %4
}

; Function Attrs: minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(argmem: readwrite)
define dso_local noundef zeroext i1 @_ZN9countdown9Countdown4tickEv(ptr noundef nonnull align 4 captures(none) dereferenceable(16) %this) local_unnamed_addr #6 align 2 {
entry:
  %call = tail call noundef zeroext i1 @_ZNK9countdown9Countdown7is_zeroEv(ptr noundef nonnull align 4 dereferenceable(16) %this) #9
  br i1 %call, label %return, label %if.end

if.end:                                           ; preds = %entry
  %s1 = getelementptr inbounds nuw i8, ptr %this, i32 12
  %0 = load i32, ptr %s1, align 4, !tbaa !20
  %cmp.not = icmp eq i32 %0, 0
  br i1 %cmp.not, label %if.else, label %if.then2

if.then2:                                         ; preds = %if.end
  %sub = add i32 %0, -1
  store i32 %sub, ptr %s1, align 4, !tbaa !20
  br label %if.end20

if.else:                                          ; preds = %if.end
  store i32 9, ptr %s1, align 4, !tbaa !20
  %s10 = getelementptr inbounds nuw i8, ptr %this, i32 8
  %1 = load i32, ptr %s10, align 4, !tbaa !19
  %cmp5.not = icmp eq i32 %1, 0
  br i1 %cmp5.not, label %if.else9, label %if.then6

if.then6:                                         ; preds = %if.else
  %sub8 = add i32 %1, -1
  store i32 %sub8, ptr %s10, align 4, !tbaa !19
  br label %if.end20

if.else9:                                         ; preds = %if.else
  store i32 5, ptr %s10, align 4, !tbaa !19
  %m1 = getelementptr inbounds nuw i8, ptr %this, i32 4
  %2 = load i32, ptr %m1, align 4, !tbaa !18
  %cmp11.not = icmp eq i32 %2, 0
  br i1 %cmp11.not, label %if.else15, label %if.then12

if.then12:                                        ; preds = %if.else9
  %sub14 = add i32 %2, -1
  store i32 %sub14, ptr %m1, align 4, !tbaa !18
  br label %if.end20

if.else15:                                        ; preds = %if.else9
  store i32 9, ptr %m1, align 4, !tbaa !18
  %3 = load i32, ptr %this, align 4, !tbaa !16
  %sub17 = add i32 %3, -1
  store i32 %sub17, ptr %this, align 4, !tbaa !16
  br label %if.end20

if.end20:                                         ; preds = %if.then6, %if.else15, %if.then12, %if.then2
  %call21 = tail call noundef zeroext i1 @_ZNK9countdown9Countdown7is_zeroEv(ptr noundef nonnull align 4 dereferenceable(16) %this) #9
  br label %return

return:                                           ; preds = %entry, %if.end20
  %retval.0 = phi i1 [ %call21, %if.end20 ], [ true, %entry ]
  ret i1 %retval.0
}

; Function Attrs: minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(argmem: read)
define dso_local noundef i32 @_ZNK9countdown9Countdown5digitEj(ptr noundef nonnull readonly align 4 captures(none) dereferenceable(16) %this, i32 noundef %i) local_unnamed_addr #4 align 2 {
entry:
  switch i32 %i, label %if.end7 [
    i32 0, label %return
    i32 1, label %if.then3
    i32 2, label %if.then6
  ]

if.then3:                                         ; preds = %entry
  %m1 = getelementptr inbounds nuw i8, ptr %this, i32 4
  br label %return

if.then6:                                         ; preds = %entry
  %s10 = getelementptr inbounds nuw i8, ptr %this, i32 8
  br label %return

if.end7:                                          ; preds = %entry
  %s1 = getelementptr inbounds nuw i8, ptr %this, i32 12
  br label %return

return:                                           ; preds = %entry, %if.end7, %if.then6, %if.then3
  %retval.0.in = phi ptr [ %s1, %if.end7 ], [ %m1, %if.then3 ], [ %s10, %if.then6 ], [ %this, %entry ]
  %retval.0 = load i32, ptr %retval.0.in, align 4, !tbaa !3
  ret i32 %retval.0
}

; Function Attrs: minsize nofree norecurse noreturn nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none)
define dso_local void @Reset_Handler() local_unnamed_addr #7 {
entry:
  %display = alloca %"class.countdown::Display", align 4
  %led = alloca %"class.countdown::RgbLed", align 4
  %count = alloca %"class.countdown::Countdown", align 4
  tail call void @_ZN9countdown10clock_initEv() #9
  store volatile i32 2097440, ptr inttoptr (i32 1073803264 to ptr), align 4096, !tbaa !3
  br label %while.cond

while.cond:                                       ; preds = %while.cond, %entry
  %0 = load volatile i32, ptr inttoptr (i32 1073790984 to ptr), align 8, !tbaa !3
  %and = and i32 %0, 2097440
  %cmp.not = icmp eq i32 %and, 2097440
  br i1 %cmp.not, label %while.end, label %while.cond

while.end:                                        ; preds = %while.cond
  call void @llvm.lifetime.start.p0(ptr nonnull %display) #8
  %call.i = call noundef ptr @_ZN9countdown7DisplayC2Ejj(ptr noundef nonnull align 4 dereferenceable(8) %display, i32 noundef 2, i32 noundef 10) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %led) #8
  %call.i33 = call noundef ptr @_ZN9countdown6RgbLedC2Ej(ptr noundef nonnull align 4 dereferenceable(4) %led, i32 noundef 18) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %count) #8
  store i32 0, ptr %count, align 4, !tbaa !16
  %m1.i.i = getelementptr inbounds nuw i8, ptr %count, i32 4
  store i32 1, ptr %m1.i.i, align 4, !tbaa !18
  %s10.i.i = getelementptr inbounds nuw i8, ptr %count, i32 8
  store i32 0, ptr %s10.i.i, align 4, !tbaa !19
  %s1.i.i = getelementptr inbounds nuw i8, ptr %count, i32 12
  store i32 0, ptr %s1.i.i, align 4, !tbaa !20
  %1 = load i32, ptr %led, align 4, !tbaa !14
  %shl1.i.i.i.i = shl i32 7, %1
  store volatile i32 %shl1.i.i.i.i, ptr inttoptr (i32 -805306344 to ptr), align 8, !tbaa !3
  %add.i = add i32 %1, 2
  %shl.i = shl nuw i32 1, %add.i
  store volatile i32 %shl.i, ptr inttoptr (i32 -805306348 to ptr), align 4, !tbaa !3
  %2 = load volatile i32, ptr inttoptr (i32 1074085928 to ptr), align 8, !tbaa !3
  %3 = load i32, ptr %display, align 4
  %shl1.i.i.i.i34 = shl i32 255, %3
  %dig_first.i.i.i = getelementptr inbounds nuw i8, ptr %display, i32 4
  %4 = load i32, ptr %dig_first.i.i.i, align 4
  %shl1.i.i7.i.i = shl i32 15, %4
  %shl.i39 = shl nuw i32 1, %1
  br label %for.cond.outer

for.cond.outer:                                   ; preds = %for.cond.outer.backedge, %while.end
  %running.0.off0.ph = phi i1 [ true, %while.end ], [ %running.0.off0.ph.be, %for.cond.outer.backedge ]
  %last_mux.0.ph = phi i32 [ %2, %while.end ], [ %last_mux.1, %for.cond.outer.backedge ]
  %last_tick.0.ph = phi i32 [ %2, %while.end ], [ %add16, %for.cond.outer.backedge ]
  %cur.0.ph = phi i32 [ 0, %while.end ], [ %cur.1, %for.cond.outer.backedge ]
  br label %for.cond

for.cond:                                         ; preds = %if.end12, %for.cond.outer
  %last_mux.0 = phi i32 [ %last_mux.0.ph, %for.cond.outer ], [ %last_mux.1, %if.end12 ]
  %cur.0 = phi i32 [ %cur.0.ph, %for.cond.outer ], [ %cur.1, %if.end12 ]
  %5 = load volatile i32, ptr inttoptr (i32 1074085928 to ptr), align 8, !tbaa !3
  %sub = sub i32 %5, %last_mux.0
  %cmp6 = icmp ugt i32 %sub, 1999
  br i1 %cmp6, label %if.then, label %if.end12

if.then:                                          ; preds = %for.cond
  %add = add nuw nsw i32 %cur.0, 1
  %and7 = and i32 %add, 3
  switch i32 %and7, label %default.unreachable [
    i32 0, label %_ZNK9countdown9Countdown5digitEj.exit
    i32 1, label %if.then3.i
    i32 2, label %if.then6.i
    i32 3, label %if.end7.i
  ]

if.then3.i:                                       ; preds = %if.then
  br label %_ZNK9countdown9Countdown5digitEj.exit

if.then6.i:                                       ; preds = %if.then
  br label %_ZNK9countdown9Countdown5digitEj.exit

default.unreachable:                              ; preds = %if.then
  unreachable

if.end7.i:                                        ; preds = %if.then
  br label %_ZNK9countdown9Countdown5digitEj.exit

_ZNK9countdown9Countdown5digitEj.exit:            ; preds = %if.then, %if.then3.i, %if.then6.i, %if.end7.i
  %retval.0.in.i = phi ptr [ %s1.i.i, %if.end7.i ], [ %m1.i.i, %if.then3.i ], [ %s10.i.i, %if.then6.i ], [ %count, %if.then ]
  %retval.0.i = load i32, ptr %retval.0.in.i, align 4, !tbaa !3
  %arrayidx.i = getelementptr inbounds nuw i32, ptr @__const._ZN9countdown4fontEj.table, i32 %retval.0.i
  %6 = load i32, ptr %arrayidx.i, align 4, !tbaa !3
  %cmp10 = icmp eq i32 %cur.0, 0
  %or = or i32 %6, 128
  %spec.select = select i1 %cmp10, i32 %or, i32 %6
  store volatile i32 %shl1.i.i.i.i34, ptr inttoptr (i32 -805306348 to ptr), align 4, !tbaa !3
  store volatile i32 %shl1.i.i7.i.i, ptr inttoptr (i32 -805306344 to ptr), align 8, !tbaa !3
  %shl.i35 = shl i32 %spec.select, %3
  %add.i36 = add i32 %4, %and7
  %shl3.i = shl nuw i32 1, %add.i36
  store volatile i32 %shl.i35, ptr inttoptr (i32 -805306344 to ptr), align 8, !tbaa !3
  store volatile i32 %shl3.i, ptr inttoptr (i32 -805306348 to ptr), align 4, !tbaa !3
  br label %if.end12

if.end12:                                         ; preds = %_ZNK9countdown9Countdown5digitEj.exit, %for.cond
  %last_mux.1 = phi i32 [ %5, %_ZNK9countdown9Countdown5digitEj.exit ], [ %last_mux.0, %for.cond ]
  %cur.1 = phi i32 [ %and7, %_ZNK9countdown9Countdown5digitEj.exit ], [ %cur.0, %for.cond ]
  %sub13 = sub i32 %5, %last_tick.0.ph
  %cmp14 = icmp ugt i32 %sub13, 999999
  %or.cond = select i1 %running.0.off0.ph, i1 %cmp14, i1 false
  br i1 %or.cond, label %if.then15, label %for.cond

if.then15:                                        ; preds = %if.end12
  %add16 = add i32 %last_tick.0.ph, 1000000
  %call17 = call noundef zeroext i1 @_ZN9countdown9Countdown4tickEv(ptr noundef nonnull align 4 dereferenceable(16) %count) #9
  br i1 %call17, label %if.then18, label %for.cond.outer.backedge

if.then18:                                        ; preds = %if.then15
  store volatile i32 %shl1.i.i.i.i, ptr inttoptr (i32 -805306344 to ptr), align 8, !tbaa !3
  store volatile i32 %shl.i39, ptr inttoptr (i32 -805306348 to ptr), align 4, !tbaa !3
  br label %for.cond.outer.backedge

for.cond.outer.backedge:                          ; preds = %if.then18, %if.then15
  %running.0.off0.ph.be = xor i1 %call17, true
  br label %for.cond.outer
}

attributes #0 = { minsize nofree norecurse nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="cortex-m0plus" "target-features"="+armv6-m,+strict-align,+thumb-mode,-aes,-bf16,-d32,-dotprod,-fp-armv8,-fp-armv8d16,-fp-armv8d16sp,-fp-armv8sp,-fp16,-fp16fml,-fp64,-fpregs,-fullfp16,-mve.fp,-neon,-sha2,-vfp2,-vfp2sp,-vfp3,-vfp3d16,-vfp3d16sp,-vfp3sp,-vfp4,-vfp4d16,-vfp4d16sp,-vfp4sp" }
attributes #1 = { minsize mustprogress nofree norecurse nounwind optsize willreturn memory(readwrite, target_mem0: none, target_mem1: none) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="cortex-m0plus" "target-features"="+armv6-m,+strict-align,+thumb-mode,-aes,-bf16,-d32,-dotprod,-fp-armv8,-fp-armv8d16,-fp-armv8d16sp,-fp-armv8sp,-fp16,-fp16fml,-fp64,-fpregs,-fullfp16,-mve.fp,-neon,-sha2,-vfp2,-vfp2sp,-vfp3,-vfp3d16,-vfp3d16sp,-vfp3sp,-vfp4,-vfp4d16,-vfp4d16sp,-vfp4sp" }
attributes #2 = { minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(none) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="cortex-m0plus" "target-features"="+armv6-m,+strict-align,+thumb-mode,-aes,-bf16,-d32,-dotprod,-fp-armv8,-fp-armv8d16,-fp-armv8d16sp,-fp-armv8sp,-fp16,-fp16fml,-fp64,-fpregs,-fullfp16,-mve.fp,-neon,-sha2,-vfp2,-vfp2sp,-vfp3,-vfp3d16,-vfp3d16sp,-vfp3sp,-vfp4,-vfp4d16,-vfp4d16sp,-vfp4sp" }
attributes #3 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #4 = { minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(argmem: read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="cortex-m0plus" "target-features"="+armv6-m,+strict-align,+thumb-mode,-aes,-bf16,-d32,-dotprod,-fp-armv8,-fp-armv8d16,-fp-armv8d16sp,-fp-armv8sp,-fp16,-fp16fml,-fp64,-fpregs,-fullfp16,-mve.fp,-neon,-sha2,-vfp2,-vfp2sp,-vfp3,-vfp3d16,-vfp3d16sp,-vfp3sp,-vfp4,-vfp4d16,-vfp4d16sp,-vfp4sp" }
attributes #5 = { minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(argmem: write) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="cortex-m0plus" "target-features"="+armv6-m,+strict-align,+thumb-mode,-aes,-bf16,-d32,-dotprod,-fp-armv8,-fp-armv8d16,-fp-armv8d16sp,-fp-armv8sp,-fp16,-fp16fml,-fp64,-fpregs,-fullfp16,-mve.fp,-neon,-sha2,-vfp2,-vfp2sp,-vfp3,-vfp3d16,-vfp3d16sp,-vfp3sp,-vfp4,-vfp4d16,-vfp4d16sp,-vfp4sp" }
attributes #6 = { minsize mustprogress nofree norecurse nosync nounwind optsize willreturn memory(argmem: readwrite) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="cortex-m0plus" "target-features"="+armv6-m,+strict-align,+thumb-mode,-aes,-bf16,-d32,-dotprod,-fp-armv8,-fp-armv8d16,-fp-armv8d16sp,-fp-armv8sp,-fp16,-fp16fml,-fp64,-fpregs,-fullfp16,-mve.fp,-neon,-sha2,-vfp2,-vfp2sp,-vfp3,-vfp3d16,-vfp3d16sp,-vfp3sp,-vfp4,-vfp4d16,-vfp4d16sp,-vfp4sp" }
attributes #7 = { minsize nofree norecurse noreturn nounwind optsize memory(readwrite, target_mem0: none, target_mem1: none) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="cortex-m0plus" "target-features"="+armv6-m,+strict-align,+thumb-mode,-aes,-bf16,-d32,-dotprod,-fp-armv8,-fp-armv8d16,-fp-armv8d16sp,-fp-armv8sp,-fp16,-fp16fml,-fp64,-fpregs,-fullfp16,-mve.fp,-neon,-sha2,-vfp2,-vfp2sp,-vfp3,-vfp3d16,-vfp3d16sp,-vfp3sp,-vfp4,-vfp4d16,-vfp4d16sp,-vfp4sp" }
attributes #8 = { nounwind }
attributes #9 = { minsize optsize }

!llvm.module.flags = !{!0, !1}
!llvm.ident = !{!2}
!llvm.errno.tbaa = !{!3}

!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{i32 1, !"min_enum_size", i32 4}
!2 = !{!"clang version 22.1.0 (https://github.com/kairolang/llvm-project a4f9e83cfb4fe474100315bfdb52910a4f5def18)"}
!3 = !{!4, !4, i64 0}
!4 = !{!"int", !5, i64 0}
!5 = !{!"omnipotent char", !6, i64 0}
!6 = !{!"Simple C++ TBAA"}
!7 = !{!8, !4, i64 0}
!8 = !{!"_ZTSN9countdown3RegE", !4, i64 0}
!9 = !{!10, !4, i64 0}
!10 = !{!"_ZTSN9countdown4PinsE", !4, i64 0}
!11 = !{!12, !4, i64 0}
!12 = !{!"_ZTSN9countdown7DisplayE", !4, i64 0, !4, i64 4}
!13 = !{!12, !4, i64 4}
!14 = !{!15, !4, i64 0}
!15 = !{!"_ZTSN9countdown6RgbLedE", !4, i64 0}
!16 = !{!17, !4, i64 0}
!17 = !{!"_ZTSN9countdown9CountdownE", !4, i64 0, !4, i64 4, !4, i64 8, !4, i64 12}
!18 = !{!17, !4, i64 4}
!19 = !{!17, !4, i64 8}
!20 = !{!17, !4, i64 12}
