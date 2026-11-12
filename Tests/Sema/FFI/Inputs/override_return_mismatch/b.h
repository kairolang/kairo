struct B {
    virtual int val() { return 1; }
    virtual B* self_() { return this; }
    virtual void tick() {}
    virtual ~B() {}
};
