"""One routed expert's three projections, without layer RMSNorm or residual."""
from opentpu import language as ol
from opentpu.kernels.lib import silu


@ol.jit
def swiglu(x, w_gate, w_up, w_down, out):
    activation = ol.quantize(ol.load(x))
    gate = ol.dot(activation, w_gate)
    up = ol.dot(activation, w_up)
    del activation  # end the ACT allocation lifetime after both projections are emitted
    hidden = silu(gate) * up
    ol.store(out, ol.dot(ol.quantize(hidden), w_down))
