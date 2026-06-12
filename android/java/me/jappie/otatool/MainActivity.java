package me.jappie.otatool;

import me.jappie.hatter.HatterActivity;

// The launcher activity. All JNI/lifecycle wiring lives in HatterActivity,
// which must stay in package me.jappie.hatter because libhatter.so resolves
// its native methods by the declaring class (Java_me_jappie_hatter_HatterActivity_*).
public class MainActivity extends HatterActivity {}
