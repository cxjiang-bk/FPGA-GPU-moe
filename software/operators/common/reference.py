"""Independent mathematical references; exact ISA results are saved separately."""
import numpy as np
from opentpu import quant as Q


def projection(x, weight, depth=128):
    return np.asarray(Q.fake_act(x, D=depth) @ Q.fake_w(weight, "int8", depth).T)


def expert(x, gate, up, down, depth=128):
    g, u = projection(x, gate, depth), projection(x, up, depth)
    h = (g / (1.0 + np.exp(-g))) * u
    return projection(h, down, depth)
