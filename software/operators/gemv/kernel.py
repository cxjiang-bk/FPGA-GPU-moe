"""A single projection: fp32 input -> QACT -> INT8 MX matmul -> fp32 output."""
from opentpu import language as ol


@ol.jit
def gemv(x, weight, out):
    activation = ol.quantize(ol.load(x))
    ol.store(out, ol.dot(activation, weight))
