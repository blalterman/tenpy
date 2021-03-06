r"""A module to handle charge conservation in tensor networks.

A detailed introduction to this module (including notations) can be found in :doc:`/intro_npc`.

This module `np_conserved` implements an class :class:`Array`
designed to make use of charge conservation in tensor networks.
The idea is that the `Array` class is used in a fashion very similar to
the `numpy.ndarray`, e.g you can call the functions :func:`tensordot` or :func:`svd`
(of this module) on them.
The structure of the algorithms (as DMRG) is thus the same as with basic numpy ndarrays.

Internally, an :class:`Array` saves charge meta data to keep track of blocks which are nonzero.
All possible operations (e.g. tensordot, svd, ...) on such arrays preserve the total charge
structure. In addition, these operations make use of the charges to figure out which of the blocks
it hase to use/combine - this is the basis for the speed-up.

**Overview**

Classes:
:class:`ChargeInfo`, :class:`LegCharge`, :class:`LegPipe`, :class:`Array`

Array creation:
:meth:`Array.from_ndarray_trivial`, :meth:`Array.from_ndarray`, :meth:`Array.from_func`,
:meth:`Array.from_func_square`, :func:`zeros`, :func:`eye_like`, :func:`diag`,

Concatenation:
:func:`concatenate`, :func:`grid_concat`, :func:`grid_outer`

Detecting charges of flat arrays:
:func:`detect_qtotal`, :func:`detect_legcharge`, :func:`detect_grid_outer_legcharge`

Contraction of some legs:
:func:`tensordot`, :func:`outer`, :func:`inner`, :func:`trace`

Linear algebra:
:func:`svd`, :func:`pinv`, :func:`norm`, :func:`qr`, :func:`expm`

Eigen systems:
:func:`eigh`, :func:`eig`, :func:`eigvalsh`, :func:`eigvals`, :func:`speigs`

"""
# Copyright 2018 TeNPy Developers

import numpy as np
cimport numpy as np
cimport cython
from cpython.mem cimport PyMem_Malloc, PyMem_Free
np.import_array()

import scipy.linalg
from scipy.linalg import blas as BLAS  # python interface to BLAS
import copy as copy_
import warnings
import itertools
import numbers

# import public API from charges
from .charges import ChargeInfo, LegCharge, LegPipe, QTYPE
from .charges cimport ChargeInfo, LegCharge, LegPipe
from .charges cimport QTYPE_t, _c_find_row_differences, _partial_qtotal

from scipy.linalg.cython_blas cimport dgemm, zgemm

from .svd_robust import svd as svd_flat
from ..tools.misc import to_iterable, anynan, argsort, inverse_permutation, list_to_dict_list
from ..tools.math import speigs as _sp_speigs
from ..tools.string import vert_join, is_non_string_iterable
from ..tools.optimization import optimize, OptimizationFlag

__all__ = [
    'QCUTOFF', 'ChargeInfo', 'LegCharge', 'LegPipe', 'Array', 'zeros', 'eye_like', 'diag',
    'concatenate', 'grid_concat', 'grid_outer', 'detect_grid_outer_legcharge', 'detect_qtotal',
    'detect_legcharge', 'trace', 'outer', 'inner', 'tensordot', 'svd', 'pinv', 'norm', 'eigh',
    'eig', 'eigvalsh', 'eigvals', 'speigs', 'qr', 'expm', 'to_iterable_arrays'
]

#: A cutoff to ignore machine precision rounding errors when determining charges
QCUTOFF = np.finfo(np.float64).eps * 10


cdef class Array(object):
    r"""A multidimensional array (=tensor) for using charge conservation.

    An `Array` represents a multi-dimensional tensor,
    together with the charge structure of its legs (for abelian charges).
    Further information can be found in :doc:`/intro_npc`.

    The default :meth:`__init__` (i.e. ``Array(...)``) does not insert any data,
    and thus yields an Array 'full' of zeros, equivalent to :func:`zeros()`.
    Further, new arrays can be created with one of :meth:`from_ndarray_trivial`,
    :meth:`from_ndarray`, or :meth:`from_func`, and of course by copying/tensordot/svd etc.

    In-place methods are indicated by a name starting with ``i``.
    (But `is_completely_blocked` is not inplace...)

    Parameters
    ----------
    legcharges : list of :class:`~tenpy.linalg.charges.LegCharge`
        The leg charges for each of the legs. The :class:`ChargeInfo` is read out from it.
    dtype : type or string
        The data type of the array entries. Defaults to np.float64.
    qtotal : 1D array of QTYPE
        The total charge of the array. Defaults to 0.

    Attributes
    ----------
    size
    stored_blocks
    rank : int
        The number of legs.
    shape : tuple(int)
        The number of indices for each of the legs.
    dtype : np.dtype
        The data type of the entries.
    chinfo : :class:`~tenpy.linalg.charges.ChargeInfo`
        The nature of the charge.
    qtotal : 1D array
        The total charge of the tensor.
    legs : list of :class:`~tenpy.linalg.charges.LegCharge`
        The leg charges for each of the legs.
    labels : dict (string -> int)
        Labels for the different legs.
    _data : list of arrays
        The actual entries of the tensor.
    _qdata : 2D array (len(_data), rank), dtype np.intp
        For each of the _data entries the qindices of the different legs.
    _qdata_sorted : Bool
        Whether self._qdata is lexsorted. Defaults to `True`,
        but *must* be set to `False` by algorithms changing _qdata.

    """
    cdef readonly int rank
    cdef readonly tuple shape
    cdef public np.dtype dtype
    cdef public ChargeInfo chinfo
    cdef public np.ndarray qtotal
    cdef public list legs
    cdef public dict labels
    cdef readonly list _data
    cdef readonly np.ndarray _qdata
    cdef readonly bint _qdata_sorted


    def __init__(self, legcharges, dtype=np.float64, qtotal=None):
        """see help(self)"""
        self.legs = list(legcharges)
        if len(self.legs) == 0:
            raise ValueError("can't have 0-rank Tensor")
        self.chinfo = self.legs[0].chinfo
        self._set_shape()
        self.dtype = np.dtype(dtype)
        self.qtotal = self.chinfo.make_valid(qtotal)
        self.labels = {}
        self._data = []
        self._qdata = np.empty((0, self.rank), dtype=np.intp)
        self._qdata_sorted = True
        self.test_sanity()

    def copy(self, deep=True):
        """Return a (deep or shallow) copy of self.

        **Both** deep and shallow copies will share ``chinfo`` and the `LegCharges` in ``legs``.

        In contrast to a deep copy, the shallow copy will also share the tensor entries,
        namely the *same* instances of ``_qdata`` and ``_data`` and ``labels``
        (and other 'immutable' properties like the shape or dtype).

        .. note ::

            Shallow copies are *not* recommended unless you know the consequences!
            See the following examples illustrating some of the pitfalls.

        Examples
        --------
        Be (very!) careful when making non-deep copies: In the following example,
        the original `a` is changed if and only if the corresponding block existed in `a` before.
        >>> b = a.copy(deep=False)  # shallow copy
        >>> b[1, 2] = 4.

        Other `inplace` operations might have no effect at all (although we don't guarantee that):

        >>> a *= 2  # has no effect on `b`
        >>> b.iconj()  # nor does this change `a`
        """
        cdef Array cp = Array(self.legs, self.dtype, self.qtotal)  # makes necessary copies
        cp.labels = self.labels.copy()
        cp._qdata_sorted = self._qdata_sorted
        if deep:
            cp._data = [b.copy() for b in self._data]
            cp._qdata = self._qdata.copy()
        else:
            cp._data = list(self._data)
            cp._qdata = self._qdata
        return cp

    @classmethod
    def from_ndarray_trivial(cls, data_flat, dtype=np.float64):
        """convert a flat numpy ndarray to an Array with trivial charge conservation.

        Parameters
        ----------
        data_flat : array_like
            The data to be converted to a Array.
        dtype : type | string
            The data type of the array entries. Defaults to ``np.float64``.

        Returns
        -------
        res : :class:`Array`
            An Array with data of data_flat.
        """
        data_flat = np.array(data_flat, dtype)
        chinfo = ChargeInfo()
        legs = [LegCharge.from_trivial(s, chinfo) for s in data_flat.shape]
        cdef Array res = cls(legs, dtype)
        res._data = [data_flat]
        res._qdata = np.zeros((1, res.rank), np.intp)
        res._qdata_sorted = True
        res.test_sanity()
        return res

    @classmethod
    def from_ndarray(cls, data_flat, legcharges, dtype=None, qtotal=None, cutoff=None):
        """convert a flat (numpy) ndarray to an Array.

        Parameters
        ----------
        data_flat : array_like
            The flat ndarray which should be converted to a npc `Array`.
            The shape has to be compatible with legcharges.
        legcharges : list of :class:`LegCharge`
            The leg charges for each of the legs. The :class:`ChargeInfo` is read out from it.
        dtype : ``np.dtype`` | string
            The data type of the array entries. Defaults to dtype of data_flat.
        qtotal : None | charges
            The total charge of the new array.
        cutoff : float
            Blocks with ``np.max(np.abs(block)) > cutoff`` are considered as zero.
            Defaults to :data:`QCUTOFF`.

        Returns
        -------
        res : :class:`Array`
            An Array with data of `data_flat`.

        See also
        --------
        detect_qtotal : used to detect ``qtotal`` if not given.
        """
        if cutoff is None:
            cutoff = QCUTOFF
        data_flat = np.asarray(data_flat)  # unspecified dtype
        if dtype is None:
            dtype = data_flat.dtype
        cdef Array res = cls(legcharges, dtype, qtotal)  # without any data
        data_flat = data_flat.astype(dtype, copy=False)
        if res.shape != data_flat.shape:
            raise ValueError("Incompatible shapes: legcharges {0!s} vs flat {1!s} ".format(
                res.shape, data_flat.shape))
        if qtotal is None:
            res.qtotal = qtotal = detect_qtotal(data_flat, legcharges, cutoff)
        data = []
        qdata = []
        for qindices in res._iter_all_blocks():
            sl = res._get_block_slices(qindices)
            if np.all(res._get_block_charge(qindices) == qtotal):
                data.append(np.array(data_flat[sl], dtype=res.dtype))  # copy data
                qdata.append(qindices)
            elif np.any(np.abs(data_flat[sl]) > cutoff):
                warnings.warn("flat array has non-zero entries in blocks incompatible with charge")
        res._data = data
        res._qdata = np.array(qdata, dtype=np.intp).reshape((len(qdata), res.rank))
        res._qdata_sorted = True
        res.test_sanity()
        return res

    @classmethod
    def from_func(cls,
                  func,
                  legcharges,
                  dtype=None,
                  qtotal=None,
                  func_args=(),
                  func_kwargs={},
                  shape_kw=None):
        """Create an Array from a numpy func.

        This function creates an array and fills the blocks *compatible* with the charges
        using `func`, where `func` is a function returning a `array_like` when given a shape,
        e.g. one of ``np.ones`` or ``np.random.standard_normal``.

        Parameters
        ----------
        func : callable
            A function-like object which is called to generate the data blocks.
            We expect that `func` returns a flat array of the given `shape` convertible to `dtype`.
            If no `shape_kw` is given, it is called like ``func(shape, *fargs, **fkwargs)``,
            otherwise as ``func(*fargs, `shape_kw`=shape, **fkwargs)``.
            `shape` is a tuple of int.
        legcharges : list of :class:`LegCharge`
            The leg charges for each of the legs. The :class:`ChargeInfo` is read out from it.
        dtype : None | type | string
            The data type of the output entries. Defaults to np.float64.
            Defaults to `None`: obtain it from the return value of the function.
            Note that this argument is not given to func, but rather a type conversion
            is performed afterwards. You might want to set a `dtype` in `func_kwargs` as well.
        qtotal : None | charges
            The total charge of the new array. Defaults to charge 0.
        func_args : iterable
            Additional arguments given to `func`.
        func_kwargs : dict
            Additional keyword arguments given to `func`.
        shape_kw : None | str
            If given, the keyword with which shape is given to `func`.

        Returns
        -------
        res : :class:`Array`
            An Array with blocks filled using `func`.
        """
        if dtype is None:
            # create a small test block to derive the dtype
            shape = (2, 2)
            if shape_kw is None:
                block = func(shape, *func_args, **func_kwargs)
            else:
                kws = func_kwargs.copy()
                kws[shape_kw] = shape
                block = func(*func_args, **kws)
            block = np.asarray(block)
            dtype = block.dtype
        cdef Array res = cls(legcharges, dtype, qtotal)  # without any data yet.
        data = []
        qdata = []
        # iterate over all qindices compatible with qtotal
        qindices = np.array([qi for qi in res._iter_all_blocks()], dtype=np.intp)
        block_charges = res._get_block_charge(qindices.T)  # .T: allows to use 2D `qindices`
        compatible = np.all(block_charges == res.qtotal, axis=1)
        for qindices in qindices[compatible]:
            shape = res._get_block_shape(qindices)
            if shape_kw is None:
                block = func(shape, *func_args, **func_kwargs)
            else:
                kws = func_kwargs.copy()
                kws[shape_kw] = shape
                block = func(*func_args, **kws)
            block = np.asarray(block, dtype=res.dtype)
            data.append(block)
            qdata.append(qindices)
        res._data = data
        res._qdata = np.array(qdata, dtype=np.intp).reshape((len(qdata), res.rank))
        res._qdata_sorted = True  # _iter_all_blocks is in lexiographic order
        res.test_sanity()
        return res

    @classmethod
    def from_func_square(cls,
                         func,
                         leg,
                         dtype=None,
                         func_args=(),
                         func_kwargs={},
                         shape_kw=None):
        """Create an Array from a numpy func.

        This function creates an array and fills the blocks *compatible* with the charges
        using `func`, where `func` is a function returning a `array_like` when given a shape,
        e.g. one of ``np.ones`` or ``np.random.standard_normal`` or the functions defined in
        :mod:`~tenpy.linalg.random_matrix`.

        Parameters
        ----------
        func : callable
            A function-like object which is called to generate the data blocks.
            We expect that `func` returns a flat array of the given `shape` convertible to `dtype`.
            If no `shape_kw` is given, it is called like ``func(shape, *fargs, **fkwargs)``,
            otherwise as ``func(*fargs, `shape_kw`=shape, **fkwargs)``.
            `shape` is a tuple of int.
        leg : :class:`LegCharge`
            The leg charges for the first leg; the second leg is set to ``leg.conj()``.
            The :class:`ChargeInfo` is read out from it.
        dtype : None | type | string
            The data type of the output entries.
            Defaults to `None`: obtain it from the return value of the function.
            Note that this argument is not given to func, but rather a type conversion
            is performed afterwards. You might want to set a `dtype` in `func_kwargs` as well.
        func_args : iterable
            Additional arguments given to `func`.
        func_kwargs : dict
            Additional keyword arguments given to `func`.
        shape_kw : None | str
            If given, the keyword with which shape is given to `func`.

        Returns
        -------
        res : :class:`Array`
            An Array with blocks filled using `func`.
        """
        blocked = leg.is_blocked()
        if not blocked:
            pipe = LegPipe([leg])
            legs = [pipe, pipe.conj()]
        else:
            legs = [leg, leg.conj()]
        cdef Array res = Array.from_func(func, legs, dtype, None, func_args, func_kwargs, shape_kw)
        if not blocked:
            return res.split_legs()
        return res

    def zeros_like(self):
        """Return a copy of self with only zeros as entries, containing no `_data`."""
        cdef Array res = self.copy(deep=False)
        res._data = []
        res._qdata = np.empty((0, res.rank), dtype=np.intp)
        res._qdata_sorted = True
        return res

    cpdef void test_sanity(Array self) except *:
        """Sanity check. Raises ValueErrors, if something is wrong."""
        if optimize(OptimizationFlag.skip_arg_checks):
            return
        if len(self.legs) == 0:
            raise ValueError("We don't allow rank-0 tensors without legs")
        for l in self.legs:
            if l.chinfo != self.chinfo:
                raise ValueError("leg has different ChargeInfo:\n{0!s}\n vs {1!s}".format(
                    l.chinfo, self.chinfo))
        if self.shape != tuple([lc.ind_len for lc in self.legs]):
            raise ValueError("shape mismatch with LegCharges\n self.shape={0!s} != {1!s}".format(
                self.shape, tuple([lc.ind_len for lc in self.legs])))
        for l in self.legs:
            l.test_sanity()
        if any([self.dtype != d.dtype for d in self._data]):
            raise ValueError("wrong dtype: {0!s} vs\n {1!s}".format(
                self.dtype, [self.dtype != d.dtype for d in self._data]))
        if self._qdata.shape[0] != self.stored_blocks or self._qdata.shape[1] != self.rank:
            raise ValueError("_qdata shape wrong")
        if self._qdata.dtype != np.intp:
            raise ValueError("wront dtype of _qdata")
        if np.any(self._qdata < 0) or np.any(self._qdata >= [l.block_number for l in self.legs]):
            raise ValueError("invalid qind in _qdata")
        if self._qdata_sorted:
            perm = np.lexsort(self._qdata.T)
            if np.any(perm != np.arange(len(perm))):
                raise ValueError("_qdata_sorted == True, but _qdata is not sorted")
        # check total charge
        block_q = np.sum([l.get_charge(qi) for l, qi in zip(self.legs, self._qdata.T)], axis=0)
        block_q = self.chinfo.make_valid(block_q)
        if np.any(block_q != self.qtotal):
            raise ValueError("some row of _qdata is incompatible with total charge")

    # properties ==============================================================

    @property
    def size(self):
        """The number of dtype-objects stored."""
        return np.sum([t.size for t in self._data], dtype=np.int_)

    @property
    def stored_blocks(self):
        """The number of (non-zero) blocks stored in :attr:`_data`."""
        return len(self._data)

    # labels ==================================================================

    cpdef get_leg_index(Array self, label):
        """translate a leg-index or leg-label to a leg-index.

        Parameters
        ----------
        label : int | string
            The leg-index directly or a label (string) set before.

        Returns
        -------
        leg_index : int
            The index of the label.

        See also
        --------
        get_leg_indices : calls get_leg_index for a list of labels.
        iset_leg_labels : set the labels of different legs.
        """
        res = self.labels.get(label, label)
        if not isinstance(res, numbers.Integral):
            raise KeyError("label not found: " + repr(label) + ", current labels" +
                           repr(self.get_leg_labels()))
        if res < 0:
            res += self.rank
        if res > self.rank or res < 0:
            raise ValueError("axis {0:d} out of rank {1:d}".format(res, self.rank))
        return res

    def get_leg_indices(self, labels):
        """Translate a list of leg-indices or leg-labels to leg indices.

        Parameters
        ----------
        labels : iterable of string/int
            The leg-labels (or directly indices) to be translated in leg-indices.

        Returns
        -------
        leg_indices : list of int
            The translated labels.

        See also
        --------
        get_leg_index : used to translate each of the single entries.
        iset_leg_labels : set the labels of different legs.
        """
        return [self.get_leg_index(l) for l in labels]

    def iset_leg_labels(self, labels):
        """Set labels for the different axes/legs. In place.

        Introduction to leg labeling can be found in :doc:`/intro_npc`.

        Parameters
        ----------
        labels : iterable (strings | None), len=self.rank
            One label for each of the legs.
            An entry can be None for an anonymous leg.

        See also
        --------
        get_leg: translate the labels to indices.
        get_legs: calls get_legs for an iterable of labels.
        """
        if len(labels) != self.rank:
            raise ValueError("Need one leg label for each of the legs.")
        self.labels = {}
        for i, l in enumerate(labels):
            if l == '':
                raise ValueError("use `None` for empty labels")
            if l is not None:
                self.labels[l] = i
        return self

    def get_leg_labels(self):
        """Return tuple of the leg labels, with `None` for anonymous legs."""
        lb = [None] * self.rank
        for k, v in self.labels.items():
            lb[v] = k
        return tuple(lb)

    def get_leg(self, label):
        """Return self.legs[self.get_leg_index(label)].

        Convenient function returning the leg corresponding to a leg label/index."""
        return self.legs[self.get_leg_index(label)]

    def ireplace_label(self, old_label, new_label):
        """Replace the leg label `old_label` with `new_label`. In place."""
        if isinstance(old_label, int):
            old_label = self.get_leg_labels()[old_label]
        old_label, new_label = str(old_label), str(new_label)
        self.labels[new_label] = self.labels[old_label]
        if new_label != old_label:
            del self.labels[old_label]
        return self

    def replace_label(self, old_label, new_label):
        """Return a shallow copy with the leg label `old_label` replaced by `new_label`."""
        return self.copy(deep=False).ireplace_label(old_label, new_label)

    def ireplace_labels(self, old_labels, new_labels):
        """Replace leg label ``old_labels[i]`` with ``new_labels[i]``. In place."""
        # can't just iterate with `ireplace_label` in case of duplicates:
        # ireplace_labels(['a', 'b'], ['b', 'a']) has to work as well!
        labels = self.labels
        axes = self.get_leg_indices(old_labels)
        for old_lbl in old_labels:
            del labels[old_lbl]
        for new_lbl, ax in zip(new_labels, axes):
            labels[new_lbl] = ax
        return self

    def replace_labels(self, old_labels, new_labels):
        """Return a shallow copy with ``old_labels[i]`` replaced by ``new_labels[i]``."""
        res = self.copy(deep=False)
        return res.ireplace_labels(old_labels, new_labels)

    # string output ===========================================================

    def __repr__(self):
        return "<npc.Array shape={0!s} charge={1!s} labels={2!s}>".format(
            self.shape, self.chinfo, self.get_leg_labels())

    def __str__(self):
        res = [repr(self)[:-1], vert_join([str(l) for l in self.legs], delim='|')]
        if np.prod(self.shape) < 100:
            res.append(str(self.to_ndarray()))
        res.append('>')
        return '\n'.join(res)

    def sparse_stats(self):
        """Returns a string detailing the sparse statistics"""
        total = np.prod(self.shape)
        if total is 0:
            return "Array without entries, one axis is empty."
        nblocks = self.stored_blocks
        stored = self.size
        nonzero = np.sum([np.count_nonzero(t) for t in self._data], dtype=np.int_)
        bs = np.array([t.size for t in self._data], dtype=np.float)
        if nblocks > 0:
            captsparse = float(nonzero) / stored
            bs_min = int(np.min(bs))
            bs_max = int(np.max(bs))
            bs_mean = np.sum(bs) / nblocks
            bs_med = np.median(bs)
            bs_var = np.var(bs)
        else:
            captsparse = 1.
            bs_min = bs_max = bs_mean = bs_med = bs_var = 0
        res = "{nonzero:d} of {total:d} entries (={nztotal:g}) nonzero,\n" \
            "stored in {nblocks:d} blocks with {stored:d} entries.\n" \
            "Captured sparsity: {captsparse:g}\n"  \
            "Block sizes min:{bs_min:d} mean:{bs_mean:.2f} median:{bs_med:.1f} " \
            "max:{bs_max:d} var:{bs_var:.2f}"

        return res.format(
            nonzero=nonzero,
            total=total,
            nztotal=nonzero / total,
            nblocks=nblocks,
            stored=stored,
            captsparse=captsparse,
            bs_min=bs_min,
            bs_max=bs_max,
            bs_mean=bs_mean,
            bs_med=bs_med,
            bs_var=bs_var)

    # accessing entries =======================================================

    def to_ndarray(self):
        """Convert self to a dense numpy ndarray."""
        res = np.zeros(self.shape, dtype=self.dtype)
        for block, slices, _, _ in self:  # that's elegant! :)
            res[slices] = block
        return res

    def __iter__(self):
        """Allow to iterate over the non-zero blocks, giving all `_data`.

        Yields
        ------
        block : ndarray
            the actual entries of a charge block
        blockslices : tuple of slices
            a slice giving the range of the block in the original tensor for each of the legs
        charges : list of charges
            the charge value(s) for each of the legs (taking `qconj` into account)
        qdat : ndarray
            the qindex for each of the legs
        """
        for block, qdat in zip(self._data, self._qdata):
            blockslices = []
            qs = []
            for (qi, l) in zip(qdat, self.legs):
                blockslices.append(l.get_slice(qi))
                qs.append(l.get_charge(qi))
            yield block, tuple(blockslices), qs, qdat

    def __getitem__(self, inds):
        """Acces entries with ``self[inds]``.

        Parameters
        ----------
        inds : tuple
            A tuple specifying the `index` for each leg.
            An ``Ellipsis`` (written as ``...``) replaces ``slice(None)`` for missing axes.
            For a single `index`, we currently support:

            - A single integer, choosing an index of the axis,
              reducing the dimension of the resulting array.
            - A ``slice(None)`` specifying the complete axis.
            - A ``slice``, which acts like a `mask` in :meth:`iproject`.
            - A 1D array_like(bool): acts like a `mask` in :meth:`iproject`.
            - A 1D array_like(int): acts like a `mask` in :meth:`iproject`,
              and if not orderd, a subsequent permuation with :meth:`permute`

        Returns
        -------
        res : `dtype`
            Only returned, if a single integer is given for all legs.
            It is the entry specified by `inds`, giving ``0.`` for non-saved blocks.
        or
        sliced : :class:`Array`
            A copy with some of the data removed by :meth:`take_slice` and/or :meth:`project`.

        Notes
        -----
        ``self[i]`` is equivalent to ``self[i, ...]``.
        ``self[i, ..., j]`` is syntactic sugar for ``self[(i, Ellipsis, i2)]``

        Raises
        ------
        IndexError
            If the number of indices is too large, or
            if an index is out of range.
        """
        int_only, inds = self._pre_indexing(inds)
        if int_only:
            pos = np.array([l.get_qindex(i) for i, l in zip(inds, self.legs)])
            block = self._get_block(pos[:, 0])
            if block is None:
                return 0.
            else:
                return block[tuple(pos[:, 1])]
        # advanced indexing
        return self._advanced_getitem(inds)

    def __setitem__(self, inds, other):
        """Assign ``self[inds] = other``.

        Should work as expected for both basic and advanced indexing as described in
        :meth:`__getitem__`.
        `other` can be:
        - a single value (if all of `inds` are integer)
        or for slicing/advanced indexing:
        - a :class:`Array`, with charges as ``self[inds]`` returned by :meth:`__getitem__`.
        - or a flat numpy array, assuming the charges as with ``self[inds]``.
        """
        int_only, inds = self._pre_indexing(inds)
        if int_only:
            pos = np.array([l.get_qindex(i) for i, l in zip(inds, self.legs)])
            block = self._get_block(pos[:, 0], insert=True, raise_incomp_q=True)
            block[tuple(pos[:, 1])] = other
            return
        # advanced indexing
        if not isinstance(other, Array):
            # if other is a flat array, convert it to an npc Array
            like_other = self.zeros_like()
            for i, leg in enumerate(like_other.legs):
                if isinstance(leg, LegPipe):
                    like_other.legs[i] = leg.to_LegCharge()
            like_other = like_other._advanced_getitem(inds)
            other = Array.from_ndarray(other, like_other.legs, self.dtype, like_other.qtotal)
        self._advanced_setitem_npc(inds, other)

    def take_slice(self, indices, axes):
        """Return a copy of self fixing `indices` along one or multiple `axes`.

        For a rank-4 Array ``A.take_slice([i, j], [1,2])`` is equivalent to ``A[:, i, j, :]``.

        Parameters
        ----------
        indices : (iterable of) int
            The (flat) index for each of the legs specified by `axes`.
        axes : (iterable of) str/int
            Leg labels or indices to specify the legs for which the indices are given.

        Returns
        -------
        sliced_self : :class:`Array`
            A copy of self, equivalent to taking slices with indices inserted in axes.

        See also
        --------
        :meth:`add_leg` : opposite action of inserting a new leg.
        """
        axes = self.get_leg_indices(to_iterable(axes))
        indices = np.asarray(to_iterable(indices), dtype=np.intp)
        if len(axes) != len(indices):
            raise ValueError("len(axes) != len(indices)")
        if indices.ndim != 1:
            raise ValueError("indices may only contain ints")
        cdef Array res = self.copy(deep=True)
        if len(axes) == 0:
            return res  # nothing to do
        # qindex and index_within_block for each of the axes
        pos = np.array([self.legs[a].get_qindex(i) for a, i in zip(axes, indices)])
        # which axes to keep
        keep_axes = [a for a in range(self.rank) if a not in axes]
        res.legs = [self.legs[a] for a in keep_axes]
        res._set_shape()
        labels = self.get_leg_labels()
        res.iset_leg_labels([labels[a] for a in keep_axes])
        # calculate new total charge
        for a, (qi, _) in zip(axes, pos):
            res.qtotal -= self.legs[a].get_charge(qi)
        res.qtotal = self.chinfo.make_valid(res.qtotal)
        # which blocks to keep
        axes = np.array(axes, dtype=np.intp)
        keep_axes = np.array(keep_axes, dtype=np.intp)
        keep_blocks = np.all(self._qdata[:, axes] == pos[:, 0], axis=1)
        res._qdata = self._qdata[np.ix_(keep_blocks, keep_axes)]
        # res._qdata_sorted is not changed
        # determine the slices to take on _data
        sl = [slice(None)] * self.rank
        for a, ri in zip(axes, pos[:, 1]):
            sl[a] = ri  # the indices within the blocks
        sl = tuple(sl)
        # finally take slices on _data
        res._data = [block[sl] for block, k in zip(res._data, keep_blocks) if k]
        return res

    def add_trivial_leg(self, axis=0, label=None, qconj=1):
        """Add a trivial leg (with just one entry) to `self`.

        Parameters
        ----------
        axis : int
            The new leg is inserted before index `axis`.
        label : str | ``None``
            If not ``None``, use it as label for the new leg.
        qconj : +1 | -1
            The direction of the new leg.

        Returns
        -------
        extended : :class:`Array`
            A (possibly) *shallow* copy of self with an additional leg of ind_len 1 and charge 0.
        """
        if axis < 0:
            axis += self.rank
        cdef Array res = self.copy(deep=False)
        leg = LegCharge.from_qflat(self.chinfo, [self.chinfo.make_valid(None)], qconj=qconj)
        res.legs.insert(axis, leg)
        res._set_shape()
        res._data = res._data[:]  # make a copy
        for j, T in enumerate(res._data):
            res._data[j] = T.reshape(T.shape[:axis] + (1, ) + T.shape[axis:])
        res._qdata = np.hstack(
            [res._qdata[:, :axis], np.zeros([len(res._data), 1], np.intp), res._qdata[:, axis:]])
        if label is not None:
            labs = list(self.get_leg_labels())
            labs.insert(axis, label)
            res.iset_leg_labels(labs)
        return res

    def add_leg(self, leg, i, axis=0, label=None):
        """Add a leg to `self`, setting the current array as slice for a given index.

        Parameters
        ----------
        leg : :class:`LegCharge`
            The charge data of the leg to be added.
        i : int
            Index within the leg for which the data of `self` should be set.
        axis : axis
            The new leg is inserted before this current axis.
        label : str | ``None``
            If not ``None``, use it as label for the new leg.

        Returns
        -------
        extended : :class:`Array`
            A copy of self with the new `leg` at axis `axis` , such that
            ``extended.take_slice(i, axis)`` returns a copy of `self`.

        See also
        --------
        :meth:`take_slice` : opposite action reducing the number of legs.
        """
        if axis < 0:
            axis += self.rank
        legs = list(self.legs)
        legs.insert(axis, leg)
        qi, _ = leg.get_qindex(i)
        qtotal = self.chinfo.make_valid(self.qtotal + leg.get_charge(qi))
        extended = Array(legs, self.dtype, qtotal)
        slices = [slice(None, None)] * self.rank
        slices[axis] = i
        extended[tuple(slices)] = self  # use existing implementation
        if label is not None:
            labs = list(self.get_leg_labels())
            labs.insert(axis, label)
            extended.iset_leg_labels(labs)
        return extended

    def extend(self, axis, extra):
        """Increase the dimension of a given axis, filling the values with zeros.

        Parameters
        ----------
        axis : int | str
            The axis (or axis-label) to be extended.
        extra : :class:`LegCharge` | int
            By what to extend, i.e. the charges to be appended to the leg of `axis`.
            An int stands for extending the length of the array by a single new block of that size
            with zero charges.

        Returns
        -------
        extended : :class:`Array`
            A copy of self with the specified axis increased.
        """
        extended = self.copy(deep=True)
        ax = self.get_leg_index(axis)
        extended.legs[ax] = extended.legs[ax].extend(extra)
        extended._set_shape()
        return extended

    # handling of charges =====================================================

    def gauge_total_charge(self, axis, newqtotal=None, new_qconj=None):
        """Changes the total charge by adjusting the charge on a certain leg.

        The total charge is given by finding a nonzero entry [i1, i2, ...] and calculating::

            qtotal = self.chinfo.make_valid(
                np.sum([l.get_charge(l.get_qindex(qi)[0])
                        for i, l in zip([i1,i2,...], self.legs)], axis=0))

        Thus, the total charge can be changed by redefining (= shifting) the LegCharge
        of a single given leg. This is exaclty what this function does.

        Parameters
        ----------
        axis : int or string
            The new leg (index or label), for which the charge is changed.
        newqtotal : charge values, defaults to 0
            The new total charge.
        new_qconj: {+1, -1, None}
            Whether the new LegCharge points inward (+1) or outward (-1) afterwards.
            By default (None) use the previous ``self.legs[leg].qconj``.

        Returns
        -------
        copy : :class:`Array`
            A shallow copy of self with ``copy.qtotal == newqtotal`` and new ``copy.legs[leg]``.
            The new leg will be a :class`LegCharge`, even if the old leg was a :class:`LegPipe`.
        """
        cdef Array res = self.copy(deep=False)
        ax = self.get_leg_index(axis)
        old_qconj = self.legs[ax].qconj
        if new_qconj is None:
            new_qconj = old_qconj
        if new_qconj not in [-1, +1]:
            raise ValueError("invalid new_qconj")
        chinfo = self.chinfo
        newqtotal = res.qtotal = chinfo.make_valid(newqtotal).copy()  # default zero
        chdiff = newqtotal - self.qtotal
        new_charges = self.legs[ax].charges + old_qconj * chdiff
        if old_qconj != new_qconj:
            new_charges = -new_charges
        new_charges = chinfo.make_valid(new_charges)
        res.legs[ax] = LegCharge.from_qind(chinfo, self.legs[ax].slices, new_charges, new_qconj)
        return res

    def add_charge(self, add_legs, chinfo=None, qtotal=None):
        """Add charges.

        Parameters
        ----------
        add_legs : iterable of :class:`LegCharge`
            One `LegCharge` for each axis of `self`, to be added to the one in :attr:`legs`.
        chargeinfo : :class:`ChargeInfo`
            The ChargeInfo for all charges; create new if ``None``.
        qtotal : None | charges
            The total charge with respect to `add_legs`.
            If ``None``, derive it from non-zero entries of ``self``.

        Returns
        -------
        charges_added : :class:`Array`
            A copy of `self`, where the LegCharges `add_legs` where added to `self.legs`.
            Note that the LegCharges are neither bunched or sorted;
            you might want to use :meth:`sort_legcharge`.
        """
        if len(add_legs) != self.rank:
            raise ValueError("wrong number of legs in `add_legs`")
        if chinfo is not None:
            chinfo2 = ChargeInfo.add([self.chinfo, add_legs[0].chinfo])
            assert chinfo == chinfo2
        else:
            chinfo = ChargeInfo.add([self.chinfo, add_legs[0].chinfo])
        legs = [
            LegCharge.from_add_charge([leg, leg2], chinfo)
            for (leg, leg2) in zip(self.legs, add_legs)
        ]
        if qtotal is None:
            for block, slices, _, _ in self:
                leg_slices = []
                for leg, sl in zip(add_legs, slices):
                    mask = np.zeros(leg.ind_len, np.bool)
                    mask[sl] = True
                    leg_slices.append(leg.project(mask)[2])
                qtotal = detect_qtotal(self.to_ndarray(), leg_slices)
                break
            else:
                raise ValueError("no non-zero entry: can't detect qtotal")
        else:
            qtotal = np.concatenate((self.qtotal, np.array(qtotal, dtype=QTYPE)))
        res = Array(legs, self.dtype, qtotal)
        for block, slices, _, _ in self:  # use __iter__
            res[slices] = block  # use __setitem__
        return res

    def drop_charge(self, charge=None, chinfo=None):
        """Drop (one of) the charges.

        Parameters
        ----------
        charge : int | str
            Number or `name` of the charge (within `chinfo`) which is to be dropped.
            ``None`` means dropping all charges.
        chinfo : :class:`ChargeInfo`
            The :class:`ChargeInfo` with `charge` dropped; create a new one if ``None``.

        Returns
        -------
        dropped : :class:`Array`
            A copy of `self`, where the specified `charge` has been removed.
            Note that the LegCharges are neither bunched or sorted;
            you might want to use :meth:`sort_legcharge`.
        """
        chinfo2 = ChargeInfo.drop(self.chinfo, charge)
        if chinfo is not None:
            assert chinfo == chinfo2
            chinfo2 = chinfo
        if charge is None:
            qtotal = None
        else:
            if isinstance(charge, str):
                charge = self.chinfo.names.index(charge)
            qtotal = np.delete(self.qtotal, charge, 0)
        res = Array([LegCharge.from_drop_charge(leg, charge, chinfo2)
                     for leg in self.legs], self.dtype, qtotal)
        for block, slices, _, _ in self:  # use __iter__
            res[slices] = block  # use __setitem__
        return res

    def change_charge(self, charge, new_qmod, new_name='', chinfo=None):
        """Change the `qmod` of one charge in `chinfo`.

        Parameters
        ----------
        charge : int | str
            Number or `name` of the charge (within `chinfo`) which is to be changed.
            ``None`` means dropping all charges.
        new_qmod : int
            The new `qmod` to be set.
        new_name : str
            The new name of the charge.
        chinfo : :class:`ChargeInfo`
            The :class:`ChargeInfo` with `qmod` of `charge` changed; create a new one if ``None``.

        Returns
        -------
        changed : :class:`Array`
            A copy of `self`, where the `qmod` of the specified `charge` has been changed.
            Note that the LegCharges are neither bunched or sorted;
            you might want to use :meth:`sort_legcharge`.
        """
        chinfo2 = ChargeInfo.change(self.chinfo, charge, new_qmod, new_name)
        if chinfo is not None:
            assert chinfo == chinfo2
            chinfo2 = chinfo
        res = self.copy(deep=True)
        res.chinfo = chinfo2
        res.legs = [
            LegCharge.from_change_charge(leg, charge, new_qmod, new_name, chinfo2)
            for leg in self.legs
        ]
        res.test_sanity()
        return res

    def is_completely_blocked(self):
        """Return bool whether all legs are blocked by charge."""
        return all([l.is_blocked() for l in self.legs])

    def sort_legcharge(self, sort=True, bunch=True):
        """Return a copy with one or all legs sorted by charges.

        Sort/bunch one or multiple of the LegCharges.
        Legs which are sorted *and* bunched are guaranteed to be blocked by charge.

        Parameters
        ----------
        sort : True | False | list of {True, False, perm}
            A single bool holds for all legs, default=True.
            Else, `sort` should contain one entry for each leg, with a bool for sort/don't sort,
            or a 1D array perm for a given permuation to apply to a leg.
        bunch : True | False | list of {True, False}
            A single bool holds for all legs, default=True.
            Whether or not to bunch at each leg, i.e. combine contiguous blocks with equal charges.

        Returns
        -------
        perm : tuple of 1D arrays
            The permutation applied to each of the legs, such that
            ``cp.to_ndarray() = self.to_ndarray(perm)``.
        result : Array
            A shallow copy of self, with legs sorted/bunched.
        """
        if sort is False or sort is True:  # ``sort in [False, True]`` doesn't work
            sort = [sort] * self.rank
        if bunch is False or bunch is True:
            bunch = [bunch] * self.rank
        if not len(sort) == len(bunch) == self.rank:
            raise ValueError("Wrong len for bunch or sort")

        # idea: encapsulate legs into pipes wich are sorted/bunched ...
        axes = []
        pipes = []
        perms = [None] * self.rank
        for ax in range(self.rank):
            if sort[ax] or bunch[ax]:
                axes.append([ax])
                leg = self.legs[ax]
                pipe = LegPipe([leg], sort=sort[ax], bunch=bunch[ax], qconj=leg.qconj)
                pipes.append(pipe)
            else:
                perms[ax] = np.arange(self.shape[ax], dtype=np.intp)
        cp = self.combine_legs(axes, pipes=pipes)
        # ... and convert pipes back to leg charges
        for ax in axes:
            ax = ax[0]
            pipe = cp.legs[ax]
            p_qind = inverse_permutation(pipe._perm)
            perms[ax] = self.legs[ax].perm_flat_from_perm_qind(p_qind)
            cp.legs[ax] = pipe.to_LegCharge()
        return tuple(perms), cp

    def isort_qdata(self):
        """(Lexiographically) sort ``self._qdata``. In place.

        Lexsort ``self._qdata`` and ``self._data`` and set ``self._qdata_sorted = True``.
        """
        if self._qdata_sorted:
            return
        if len(self._qdata) < 2:
            self._qdata_sorted = True
            return
        perm = np.lexsort(self._qdata.T)
        self._qdata = self._qdata[perm, :]
        self._data = [self._data[p] for p in perm]
        self._qdata_sorted = True

    # reshaping ===============================================================

    def make_pipe(self, axes, **kwargs):
        """Generates a :class:`~tenpy.linalg.charges.LegPipe` for specified axes.

        Parameters
        ----------
        axes : iterable of str|int
            The leg labels for the axes which should be combined. Order matters!
        **kwargs :
            Additional keyword arguments given to :class:`~tenpy.linalg.charges.LegPipe`.

        Returns
        -------
        pipe : :class:`~tenpy.linalg.charges.LegPipe`
            A pipe of the legs specified by axes.
        """
        axes = self.get_leg_indices(axes)
        legs = [self.legs[a] for a in axes]
        return LegPipe(legs, **kwargs)

    def combine_legs(self, combine_legs, new_axes=None, pipes=None, qconj=None):
        """Reshape: combine multiple legs into multiple pipes. If necessary, transpose before.

        Parameters
        ----------
        combine_legs : (iterable of) iterable of {str|int}
            Bundles of leg indices or labels, which should be combined into a new output pipes.
            If multiple pipes should be created, use a list fore each new pipe.
        new_axes : None | (iterable of) int
            The leg-indices, at which the combined legs should appear in the resulting array.
            Default: for each pipe the position of its first pipe in the original array,
            (taking into account that some axes are 'removed' by combining).
            Thus no transposition is perfomed if `combine_legs` contains only contiguous ranges.
        pipes : None | (iterable of) {:class:`LegPipes` | None}
            Optional: provide one or multiple of the resulting LegPipes to avoid overhead of
            computing new leg pipes for the same legs multiple times.
            The LegPipes are conjugated, if that is necessary for compatibility with the legs.
        qconj : (iterable of) {+1, -1}
            Specify whether new created pipes point inward or outward. Defaults to +1.
            Ignored for given `pipes`, which are not newly calculated.

        Returns
        -------
        reshaped : :class:`Array`
            A copy of self, whith some legs combined into pipes as specified by the arguments.

        See also
        --------
        :meth:`split_legs` : inverse reshaping splitting LegPipes.

        Notes
        -----
        Labels are inherited from self.
        New pipe labels are generated as ``'(' + '.'.join(*leglabels) + ')'``.
        For these new labels, previously unlabeled legs are replaced by ``'?#'``,
        where ``#`` is the leg-index in the original tensor `self`.

        Examples
        --------
        >>> oldarray.iset_leg_labels(['a', 'b', 'c', 'd', 'e'])
        >>> c1 = oldarray.combine_legs([1, 2], qconj=-1)  # only single output pipe
        >>> c1.get_leg_labels()
        ['a', '(b.c)', 'd', 'e']

        Indices of `combine_legs` refer to the original array.
        If transposing is necessary, it is performed automatically:

        >>> c2 = oldarray.combine_legs([[0, 3], [4, 1]], qconj=[+1, -1]) # two output pipes
        >>> c2.get_leg_labels()
        ['(a.d)', 'c', '(e.b)']
        >>> c3 = oldarray.combine_legs([['a', 'd'], ['e', 'b']], new_axes=[2, 1],
        >>>                            pipes=[c2.legs[0], c2.legs[2]])
        >>> c3.get_leg_labels()
        ['b', '(e.b)', '(a.d)']
        """
        # bring arguments into a standard form
        combine_legs = list(combine_legs)  # convert iterable to list
        # check: is combine_legs `iterable(iterable(int|str))` or `iterable(int|str)` ?
        if not is_non_string_iterable(combine_legs[0]):
            # the first entry is (int|str) -> only a single new pipe
            combine_legs = [combine_legs]
            if new_axes is not None:
                new_axes = to_iterable(new_axes)
            if pipes is not None:
                pipes = to_iterable(pipes)
        pipes = self._combine_legs_make_pipes(combine_legs, pipes, qconj)  # out-sourced
        # good for index tricks: convert combine_legs into arrays
        combine_legs = [np.asarray(self.get_leg_indices(cl), dtype=np.intp) for cl in combine_legs]
        all_combine_legs = np.concatenate(combine_legs)
        if len(set(all_combine_legs)) != len(all_combine_legs):
            raise ValueError("got a leg multiple times: " + str(combine_legs))
        new_axes, transp = self._combine_legs_new_axes(combine_legs, new_axes)  # out-sourced
        # permute arguments sucht that new_axes is sorted ascending
        perm_args = np.argsort(new_axes)
        combine_legs = [combine_legs[p] for p in perm_args]
        pipes = [pipes[p] for p in perm_args]
        new_axes = [new_axes[p] for p in perm_args]

        # labels: replace non-set labels with '?#' (*before* transpose
        labels = [(l if l is not None else '?' + str(i))
                  for i, l in enumerate(self.get_leg_labels())]

        # transpose if necessary
        if transp != tuple(range(self.rank)):
            res = self.copy(deep=False)
            res.iset_leg_labels(labels)
            res = res.itranspose(transp)
            inv_transp = inverse_permutation(transp)
            tr_combine_legs = [[inv_transp[a] for a in cl] for cl in combine_legs]
            return res.combine_legs(tr_combine_legs, new_axes=new_axes, pipes=pipes)
        # if we come here, combine_legs has the form of `tr_combine_legs`.

        # the **main work** of copying the data is sourced out, now that we have the
        # standard form of our arguments
        res = self._combine_legs_worker(combine_legs, new_axes, pipes)

        # get new labels
        pipe_labels = [self._combine_leg_labels([labels[c] for c in cl]) for cl in combine_legs]
        for na, p, plab in zip(new_axes, pipes, pipe_labels):
            labels[na:na + p.nlegs] = [plab]
        res.iset_leg_labels(labels)
        return res

    def split_legs(self, axes=None, cutoff=0.):
        """Reshape: opposite of combine_legs: split (some) legs which are LegPipes.

        Reverts :meth:`combine_legs` (except a possibly performed `transpose`).
        The splited legs are replacing the LegPipes at their position, see the examples below.
        Labels are split reverting what was done in :meth:`combine_legs`.
        '?#' labels are replaced with ``None``.

        Parameters
        ----------
        axes : (iterable of) int|str
            Leg labels or indices determining the axes to split.
            The corresponding entries in self.legs must be :class:`LegPipe` instances.
            Defaults to all legs, which are :class:`LegPipe` instances.
        cutoff : float
            Splitted data blocks with ``np.max(np.abs(block)) > cutoff`` are considered as zero.
            Defaults to 0.

        Returns
        -------
        reshaped : :class:`Array`
            A copy of self where the specified legs are splitted.

        See also
        --------
        :meth:`combine_legs` : this is reversed by split_legs.

        Examples
        --------
        Given a rank-5 Array `old_array`, you can combine it and split it again:

        >>> old_array.iset_leg_labels(['a', 'b', 'c', 'd', 'e'])
        >>> comb_array = old_array.combine_legs([[0, 3], [2, 4]] )
        >>> comb_array.get_leg_labels()
        ['(a.d)', 'b', '(c.e)']
        >>> split_array = comb_array.split_legs([0, 2])
        >>> split_array.get_leg_labels()
        ['a', 'd', 'b', 'c', 'e']
        """
        if axes is None:
            axes = [i for i, l in enumerate(self.legs) if isinstance(l, LegPipe)]
        else:
            axes = self.get_leg_indices(to_iterable(axes))
            if len(set(axes)) != len(axes):
                raise ValueError("can't split a leg multiple times!")
        for ax in axes:
            if not isinstance(self.legs[ax], LegPipe):
                raise ValueError("can't split leg {ax:d} which is not a LegPipe".format(ax=ax))
        if len(axes) == 0:
            return self.copy(deep=True)

        res = self._split_legs_worker(axes, cutoff)

        labels = list(self.get_leg_labels())
        for a in sorted(axes, reverse=True):
            labels[a:a + 1] = self._split_leg_label(labels[a], self.legs[a].nlegs)
        res.iset_leg_labels(labels)
        return res

    def as_completely_blocked(self):
        """Gives a version of self which is completely blocked by charges.

        Functions like :func:`svd` or :func:`eigh` require a complete blocking by charges.
        This can be achieved by encapsulating each leg which is not completely blocked into a
        :class:`LegPipe` (containing only that single leg). The LegPipe will then contain all
        necessary information to revert the blocking.

        Returns
        -------
        encapsulated_axes : list of int
            The leg indices which have been encapsulated into Pipes.
        blocked_self : :class:`Array`
            Self (if ``len(encapsulated_axes) = 0``) or a copy of self,
            which is completely blocked.
        """
        enc_axes = [a for a, l in enumerate(self.legs) if not l.is_blocked()]
        if len(enc_axes) == 0:
            return enc_axes, self
        qconj = [self.legs[a].qconj for a in enc_axes]
        return enc_axes, self.combine_legs([[a] for a in enc_axes], qconj=qconj)

    def squeeze(self, axes=None):
        """Like ``np.squeeze``.

        If a squeezed leg has non-zero charge, this charge is added to :attr:`qtotal`.

        Parameters
        ----------
        axes : None | (iterable of) {int|str}
            Labels or indices of the legs which should be 'squeezed', i.e. the legs removed.
            The corresponding legs must be trivial, i.e., have `ind_len` 1.

        Returns
        -------
        squeezed : :class:Array | scalar
            A scalar of ``self.dtype``, if all axes were squeezed.
            Else a copy of ``self`` with reduced ``rank`` as specified by `axes`.
        """
        if axes is None:
            axes = tuple([a for a in range(self.rank) if self.shape[a] == 1])
        else:
            axes = tuple(self.get_leg_indices(to_iterable(axes)))
        for a in axes:
            if self.shape[a] != 1:
                raise ValueError("Tried to squeeze non-unit leg")
        keep = [a for a in range(self.rank) if a not in axes]
        if len(keep) == 0:
            index = tuple([0] * self.rank)
            return self[index]
        cdef Array res = self.copy(deep=False)
        # adjust qtotal
        res.legs = [self.legs[a] for a in keep]
        res._set_shape()
        for a in axes:
            res.qtotal -= self.legs[a].get_charge(0)
        res.qtotal = self.chinfo.make_valid(res.qtotal)

        labels = self.get_leg_labels()
        res.iset_leg_labels([labels[a] for a in keep])

        res._data = [np.squeeze(t, axis=axes).copy() for t in self._data]
        res._qdata = self._qdata[:, np.array(keep)]
        # res._qdata_sorted doesn't change
        return res

    # data manipulation =======================================================

    def astype(self, dtype, copy=True):
        """Return copy with new dtype, upcasting all blocks in ``_data``.

        Parameters
        ----------
        dtype : convertible to a np.dtype
            The new data type.
            If None, deduce the new dtype as common type of ``self._data``.
        copy : bool
            Whether to make a copy of the blocks even if the type didn't change.

        Returns
        -------
        copy : :class:`Array`
            Deep copy of self with new dtype.
        """
        cdef Array cp = self.copy(deep=False)  # manual deep copy: don't copy every block twice
        cp._qdata = cp._qdata.copy()
        if dtype is None:
            dtype = np.find_common_type([d.dtype for d in self._data], [])
        cp.dtype = np.dtype(dtype)
        cp._data = [d.astype(self.dtype, copy=True) for d in self._data]
        return cp

    def ipurge_zeros(self, cutoff=QCUTOFF, norm_order=None):
        """Removes ``self._data`` blocks with *norm* less than cutoff. In place.

        Parameters
        ----------
        cutoff : float
            Blocks with norm <= `cutoff` are removed. defaults to :data:`QCUTOFF`.
        norm_order :
            A valid `ord` argument for `np.linalg.norm`.
            Default ``None`` gives the Frobenius norm/2-norm for matrices/everything else.
            Note that this differs from other methods, e.g. :meth:`from_ndarray`,
            which use the maximum norm.
        """
        if len(self._data) == 0:
            return self
        norm = np.array([np.linalg.norm(t, ord=norm_order) for t in self._data])
        keep = (norm > cutoff)  # bool array
        self._data = [t for t, k in zip(self._data, keep) if k]
        self._qdata = self._qdata[keep]
        # self._qdata_sorted is preserved
        return self

    def iproject(self, mask, axes):
        """Applying masks to one or multiple axes. In place.

        This function is similar as `np.compress` with boolean arrays
        For each specified axis, a boolean 1D array `mask` can be given,
        which chooses the indices to keep.

        .. warning ::
            Although it is possible to use an 1D int array as a mask, the order is ignored!
            If you need to permute an axis, use :meth:`permute` or :meth:`sort_legcharge`.

        Parameters
        ----------
        mask : (list of) 1D array(bool|int)
            For each axis specified by `axes` a mask, which indices of the axes should be kept.
            If `mask` is a bool array, keep the indices where `mask` is True.
            If `mask` is an int array, keep the indices listed in the mask, *ignoring* the
            order or multiplicity.
        axes : (list of) int | string
            The `i`th entry in this list specifies the axis for the `i`th entry of `mask`,
            either as an int, or with a leg label.
            If axes is just a single int/string, specify just a single mask.

        Returns
        -------
        map_qind : list of 1D arrays
            The mapping of qindices for each of the specified axes.
        block_masks: list of lists of 1D bool arrays
            ``block_masks[a][qind]`` is a boolen mask which indices to keep
            in block ``qindex`` of ``axes[a]``.
        """
        if axes is not to_iterable(axes):
            mask = [mask]
        axes = self.get_leg_indices(to_iterable(axes))
        mask = [np.asarray(m) for m in mask]
        if len(axes) != len(mask):
            raise ValueError("len(axes) != len(mask)")
        if len(axes) == 0:
            return [], []  # nothing to do.
        for i, m in enumerate(mask):
            # convert integer masks to bool masks
            if m.dtype != np.bool_:
                mask[i] = np.zeros(self.shape[axes[i]], dtype=np.bool_)
                np.put(mask[i], m, True)
        # Array views may share ``_qdata`` views, so make a copy of _qdata before manipulating
        self._qdata = self._qdata.copy()
        block_masks = []
        proj_data = np.arange(self.stored_blocks)
        map_qind = []
        for m, a in zip(mask, axes):
            l = self.legs[a]
            m_qind, bm, self.legs[a] = l.project(m)
            map_qind.append(m_qind)
            block_masks.append(bm)
            q = self._qdata[:, a] = m_qind[self._qdata[:, a]]
            piv = (q >= 0)
            self._qdata = self._qdata[piv]  # keeps dimension
            # self._qdata_sorted is preserved
            proj_data = proj_data[piv]
        self._set_shape()
        # finally project out the blocks
        data = []
        for i, iold in enumerate(proj_data):
            block = self._data[iold]
            subidx = [slice(d) for d in block.shape]
            for m, a in zip(block_masks, axes):
                subidx[a] = m[self._qdata[i, a]]
                block = np.compress(m[self._qdata[i, a]], block, axis=a)
            data.append(block)
        self._data = data
        return map_qind, block_masks

    def permute(self, perm, axis):
        """Apply a permutation in the indices of an axis.

        Similar as np.take with a 1D array.
        Roughly equivalent to ``res[:, ...] = self[perm, ...]`` for the corresponding `axis`.
        Note: This function is quite slow, and usually not needed!

        Parameters
        ----------
        perm : array_like 1D int
            The permutation which should be applied to the leg given by `axis`.
        axis : str | int
            A leg label or index specifying on which leg to take the permutation.

        Returns
        -------
        res : :class:`Array`
            A copy of self with leg `axis` permuted, such that
            ``res[i, ...] = self[perm[i], ...]`` for ``i`` along `axis`.

        See also
        --------
        sort_legcharge : can also be used to perform a general permutation.
            Preferable, since it is faster for permutations which don't mix charge blocks.
        """
        axis = self.get_leg_index(axis)
        perm = np.asarray(perm, dtype=np.intp)
        oldleg = self.legs[axis]
        if len(perm) != oldleg.ind_len:
            raise ValueError("permutation has wrong length")
        inv_perm = inverse_permutation(perm)
        newleg = LegCharge.from_qflat(self.chinfo, oldleg.to_qflat()[perm], oldleg.qconj)
        newleg = newleg.bunch()[1]
        cdef Array res = self.copy(deep=False)  # data is replaced afterwards
        res.legs[axis] = newleg
        qdata_axis = self._qdata[:, axis]
        new_block_idx = [slice(None)] * self.rank
        old_block_idx = [slice(None)] * self.rank
        data = []
        qdata = {}  # dict for fast look up: tuple(indices) -> _data index
        for old_qind, (beg, end) in enumerate(oldleg._slice_start_stop()):
            old_range = range(beg, end)
            for old_data_index in np.nonzero(qdata_axis == old_qind)[0]:
                old_block = self._data[old_data_index]
                old_qindices = self._qdata[old_data_index]
                new_qindices = old_qindices.copy()
                for i_old in old_range:
                    i_new = inv_perm[i_old]
                    qi_new, within_new = newleg.get_qindex(i_new)
                    new_qindices[axis] = qi_new
                    # look up new_qindices in `qdata`, insert them if necessary
                    new_data_ind = qdata.setdefault(tuple(new_qindices), len(data))
                    if new_data_ind == len(data):
                        # insert new block
                        data.append(np.zeros(res._get_block_shape(new_qindices)))
                    new_block = data[new_data_ind]
                    # copy data
                    new_block_idx[axis] = within_new
                    old_block_idx[axis] = i_old - beg
                    new_block[tuple(new_block_idx)] = old_block[tuple(old_block_idx)]
        # data blocks copied
        res._data = data
        res._qdata_sorted = False
        res_qdata = res._qdata = np.empty((len(data), self.rank), dtype=np.intp)
        for qindices, i in qdata.items():
            res_qdata[i] = qindices
        return res

    def itranspose(self, axes=None):
        """Transpose axes like `np.transpose`. In place.

        Parameters
        ----------
        axes: iterable (int|string), len ``rank`` | None
            The new order of the axes. By default (None), reverse axes.
        """
        if axes is None:
            axes = tuple(reversed(range(self.rank)))
        else:
            axes = tuple(self.get_leg_indices(axes))
            if len(axes) != self.rank or len(set(axes)) != self.rank:
                raise ValueError("axes has wrong length: " + str(axes))
            if axes == tuple(range(self.rank)):
                return self  # nothing to do
        axes_arr = np.array(axes)
        self.legs = [self.legs[a] for a in axes]
        self._set_shape()
        labs = self.get_leg_labels()
        self.iset_leg_labels([labs[a] for a in axes])
        self._qdata = self._qdata[:, axes_arr]
        self._qdata_sorted = False
        self._data = [np.transpose(block, axes) for block in self._data]
        return self

    def transpose(self, axes=None):
        """Like :meth:`itranspose`, but on a deep copy."""
        cp = self.copy(deep=True)
        cp.itranspose(axes)
        return cp

    def iswapaxes(self, axis1, axis2):
        """Similar as ``np.swapaxes``. In place."""
        axis1 = self.get_leg_index(axis1)
        axis2 = self.get_leg_index(axis2)
        if axis1 == axis2:
            return self  # nothing to do
        swap = np.arange(self.rank, dtype=np.intp)
        swap[axis1], swap[axis2] = axis2, axis1
        legs = self.legs
        legs[axis1], legs[axis2] = legs[axis2], legs[axis1]
        for k, v in self.labels.items():
            if v == axis1:
                self.labels[k] = axis2
            if v == axis2:
                self.labels[k] = axis1
        self._set_shape()
        self._qdata = self._qdata[:, swap]
        self._qdata_sorted = False
        self._data = [t.swapaxes(axis1, axis2) for t in self._data]
        return self

    def iscale_axis(self, s, axis=-1):
        """Scale with varying values along an axis. In place.

        Rescale to ``new_self[i1, ..., i_axis, ...] = s[i_axis] * self[i1, ..., i_axis, ...]``.

        Parameters
        ----------
        s : 1D array, len=self.shape[axis]
            The vector with which the axis should be scaled.
        axis : str|int
            The leg label or index for the axis which should be scaled.

        See also
        --------
        iproject : can be used to discard indices for which s is zero.
        """
        axis = self.get_leg_index(axis)
        s = np.asarray(s)
        if s.shape != (self.shape[axis], ):
            raise ValueError("s has wrong shape: " + str(s.shape))
        self.dtype = np.find_common_type([self.dtype], [s.dtype])
        leg = self.legs[axis]
        if axis != self.rank - 1:
            self._data = [
                np.swapaxes(np.swapaxes(t, axis, -1) * s[leg.get_slice(qi)], axis, -1)
                for qi, t in zip(self._qdata[:, axis], self._data)
            ]
        else:  # optimize: no need to swap axes, if axis is -1.
            self._data = [
                t * s[leg.get_slice(qi)]  # (it's slightly faster for large arrays)
                for qi, t in zip(self._qdata[:, axis], self._data)
            ]
        return self

    def scale_axis(self, s, axis=-1):
        """Same as :meth:`iscale_axis`, but return a (deep) copy."""
        cdef Array res = self.copy(deep=False)
        res._qdata = res._qdata.copy()
        res.iscale_axis(s, axis)
        return res

    # block-wise operations == element wise with numpy ufunc

    def iunary_blockwise(self, func, *args, **kwargs):
        """Roughly ``self = f(self)``, block-wise. In place.

        Applies an unary function `func` to the non-zero blocks in ``self._data``.

        .. note ::
            Assumes implicitly that ``func(np.zeros(...), *args, **kwargs)`` gives 0,
            since we don't let `func` act on zero blocks!

        Parameters
        ----------
        func : function
            A function acting on flat arrays, returning flat arrays.
            It is called like ``new_block = func(block, *args, **kwargs)``.
        *args :
            Additional arguments given to function *after* the block.
        **kwargs :
            Keyword arguments given to the function.

        Examples
        --------
        >>> a.iunaray_blockwise(np.real)  # get real part
        >>> a.iunaray_blockwise(np.conj)  # same data as a.iconj(), but doesn't charge conjugate.
        """
        self._data = [func(t, *args, **kwargs) for t in self._data]
        if len(self._data) > 0:
            self.dtype = self._data[0].dtype
        return self

    def unary_blockwise(self, func, *args, **kwargs):
        """Roughly ``return func(self)``, block-wise. Copies.

        Same as :meth:`iunary_blockwise`, but makes a **shallow** copy first."""
        res = self.copy(deep=False)
        return res.iunary_blockwise(func, *args, **kwargs)

    def iconj(self, complex_conj=True):
        """Wraper around :meth:`self.conj` with ``inplace=True``."""
        return self.conj(complex_conj, inplace=True)

    def conj(self, complex_conj=True, inplace=False):
        """Conjugate: complex conjugate data, conjugate charge data.

        Conjugate all legs, set negative qtotal.

        Labeling: takes 'a' -> 'a*', 'a*'-> 'a' and
        '(a,(b*,c))' -> '(a*, (b, c*))'

        Parameters
        ----------
        complex_conj : bool
            Whether the data should be complex conjugated.
        inplace : bool
            Whether to apply changes to `self`, or to return a *deep* copy.
        """
        cdef Array res
        cdef char _c = b'c'
        if self.dtype.kind == _c and complex_conj:
            if inplace:
                res = self.iunary_blockwise(np.conj)
            else:
                res = self.unary_blockwise(np.conj)
        else:
            if inplace:
                res = self
            else:
                res = self.copy(deep=True)
        res.qtotal = -res.qtotal
        res.legs = [l.conj() for l in res.legs]
        labels = {}
        for lab, ax in res.labels.items():
            labels[self._conj_leg_label(lab)] = ax
        res.labels = labels
        return res

    def complex_conj(self):
        """Return copy which is complex conjugated *without* conjugating the charge data."""
        return self.unary_blockwise(np.conj)

    def norm(self, ord=None, convert_to_float=True):
        """Norm of flattened data.

        See :func:`norm` for details."""
        if ord == 0:
            return np.sum([np.count_nonzero(t) for t in self._data], dtype=np.int_)
        if convert_to_float:
            new_type = np.find_common_type([np.float_, self.dtype], [])  # int -> float
            if new_type != self.dtype:
                return self.astype(new_type).norm(ord, False)
        block_norms = [np.linalg.norm(t.reshape(-1), ord) for t in self._data]
        # ``.reshape(-1) gives a 1D view and is thus faster than ``.flatten()``
        # add a [0] in the list to ensure correct results for ``ord=-inf``
        return np.linalg.norm(block_norms + [0], ord)

    def __neg__(self):
        """return ``-self``"""
        return self.unary_blockwise(np.negative)

    def ibinary_blockwise(self, func, other, *args, **kwargs):
        """Roughly ``self = func(self, other)``, block-wise. In place.

        Applies a binary function 'block-wise' to the non-zero blocks of
        ``self._data`` and ``other._data``, storing result in place.
        Assumes that `other` is an :class:`Array` as well, with the same shape
        and compatible legs.

        .. note ::
            Assumes implicitly that
            ``func(np.zeros(...), np.zeros(...), *args, **kwargs)`` gives 0,
            since we don't let `func` act on zero blocks!

        Examples
        --------
        >>> a.ibinary_blockwise(np.add, b)  # equivalent to ``a += b``, if ``b`` is an `Array`.
        >>> a.ibinary_blockwise(np.max, b)  # overwrites ``a`` to ``a = max(a, b)``
        """
        for self_leg, other_leg in zip(self.legs, other.legs):
            self_leg.test_equal(other_leg)
        if np.any(self.qtotal != other.qtotal):
            raise ValueError("Arrays can't have different `qtotal`!")
        self.isort_qdata()
        other.isort_qdata()

        adata = self._data
        bdata = other._data
        aq = self._qdata
        bq = other._qdata
        Na, Nb = len(aq), len(bq)

        # If the q_dat structure is identical, we can immediately run through the data.
        if Na == Nb and np.array_equiv(aq, bq):
            self._data = [func(at, bt, *args, **kwargs) for at, bt in zip(adata, bdata)]
        else:  # otherwise we have to step through comparing left and right qdata
            i, j = 0, 0
            qdata = []
            data = []
            while i < Na or j < Nb:
                if i < Na and j < Nb and tuple(aq[i]) == tuple(bq[j]):  # a and b are non-zero
                    data.append(func(adata[i], bdata[j], *args, **kwargs))
                    qdata.append(aq[i])
                    i += 1
                    j += 1
                elif i >= Na or j < Nb and (tuple(aq[i, ::-1]) > tuple(bq[j, ::-1])):  # a is 0
                    data.append(func(np.zeros_like(bdata[j]), bdata[j], *args, **kwargs))
                    qdata.append(bq[j])
                    j += 1
                elif j >= Nb or (tuple(aq[i, ::-1]) < tuple(bq[j, ::-1])):  # b is 0
                    data.append(func(adata[i], np.zeros_like(adata[i]), *args, **kwargs))
                    qdata.append(aq[i])
                    i += 1
                else:  # tested a == b or a < b or a > b, so this should never happen
                    assert False
                # if both are zero, we assume f(0, 0) = 0
            self._data = data
            self._qdata = np.array(qdata, dtype=np.intp).reshape((len(data), self.rank))
            # ``self._qdata_sorted = True`` was set by self.isort_qdata
        if len(self._data) > 0:
            self.dtype = np.find_common_type([d.dtype for d in self._data], [])
            self._data = [np.asarray(a, dtype=self.dtype) for a in self._data]
        return self

    def binary_blockwise(self, func, other, *args, **kwargs):
        """Roughly ``return func(self, other)``, block-wise. Copies.

        Same as :meth:`ibinary_blockwise`, but makes a **shallow** copy first.
        """
        res = self.copy(deep=False)
        return res.ibinary_blockwise(func, other, *args, **kwargs)

    def matvec(self, other):
        """This function is used by the Lanczos algorithm needed for DMRG.

        It is supposed to calculate the matrix - vector - product
        for a rank-2 matrix ``self`` and a rank-1 vector `other`.
        """
        return tensordot(self, other, axes=1)

    def __add__(self, other):
        """Return ``self + other``."""
        if not isinstance(self, Array):  # cython ignores __radd__...
            return other + self
        if isinstance(other, Array):
            return self.binary_blockwise(np.add, other)
        elif np.isscalar(other):
            warnings.warn("block-wise add ignores zero blocks!")
            return self.unary_blockwise(np.add, other)
        elif isinstance(other, np.ndarray):
            return self.to_ndarray().__add__(other)
        raise NotImplemented  # unknown type of other

    def __iadd__(self, other):
        """``self += other``."""
        if isinstance(other, Array):
            return self.ibinary_blockwise(np.add, other)
        elif np.isscalar(other):
            warnings.warn("block-wise add ignores zero blocks!")
            return self.iunary_blockwise(np.add, other)
        # can't convert to numpy array in place, thus no ``self += ndarray``
        raise NotImplemented  # unknown type of other

    def __sub__(self, other):
        """Return ``self - other``."""
        if isinstance(other, Array):
            return self.binary_blockwise(np.subtract, other)
        elif np.isscalar(other):
            warnings.warn("block-wise subtract ignores zero blocks!")
            return self.unary_blockwise(np.subtract, other)
        elif isinstance(other, np.ndarray):
            return self.to_ndarray().__sub__(other)
        raise NotImplemented  # unknown type of other

    def __isub__(self, other):
        """``self -= other``."""
        if isinstance(other, Array):
            return self.ibinary_blockwise(np.subtract, other)
        elif np.isscalar(other):
            warnings.warn("block-wise subtract ignores zero blocks!")
            return self.iunary_blockwise(np.subtract, other)
        # can't convert to numpy array in place, thus no ``self -= ndarray``
        raise NotImplementedError()

    def __mul__(self, other):
        """Return ``self * other`` for scalar ``other``.

        Use explicit functions for matrix multiplication etc."""
        if not isinstance(self, Array):  # cython ignores __rmul__...
            return other*self
        if np.isscalar(other):
            if other == 0.:
                return self.zeros_like()
            return self.unary_blockwise(np.multiply, other)
        raise NotImplementedError

    def __imul__(self, other):
        """``self *= other`` for scalar `other`."""
        if np.isscalar(other):
            if other == 0.:
                self._data = []
                self._qdata = np.empty((0, self.rank), np.intp)
                self._qdata_sorted = True
                return self
            return self.iunary_blockwise(np.multiply, other)
        raise NotImplemented

    def __truediv__(self, other):
        """Return ``self / other`` for scalar `other`."""
        if np.isscalar(other):
            if other == 0.:
                raise ZeroDivisionError("a/b for b=0. Types: {0!s}, {1!s}".format(
                    type(self), type(other)))
            return self.__mul__(1. / other)
        raise NotImplemented

    def __itruediv__(self, other):
        """``self /= other`` for scalar `other`."""
        if np.isscalar(other):
            if other == 0.:
                raise ZeroDivisionError("a/b for b=0. Types: {0!s}, {1!s}".format(
                    type(self), type(other)))
            return self.__imul__(1. / other)
        raise NotImplemented

    # private functions =======================================================

    def _set_shape(self):
        """Deduce self.shape from self.legs."""
        if len(self.legs) == 0:
            raise ValueError("We don't allow 0-dimensional arrays. Why should we?")
        self.shape = tuple([lc.ind_len for lc in self.legs])
        self.rank = len(self.legs)

    def _iter_all_blocks(self):
        """Generator to iterate over all combinations of qindices in lexiographic order.

        Yields
        ------
        qindices : tuple of int
            A qindex for each of the legs.
        """
        for block_inds in itertools.product(*[range(l.block_number)
                                              for l in reversed(self.legs)]):
            # loop over all charge sectors in lex order (last leg most siginificant)
            yield tuple(block_inds[::-1])  # back to legs in correct order

    def _get_block_charge(self, qindices):
        """Returns the charge of a block selected by `qindices`.

        The charge of a single block is defined as ::

            qtotal = sum_{legs l} legs[l].get_charges(qindices[l])) modulo qmod
        """
        q = np.sum([l.get_charge(qi) for l, qi in zip(self.legs, qindices)], axis=0)
        return self.chinfo.make_valid(q)

    def _get_block_slices(self, qindices):
        """Returns tuple of slices for a block selected by `qindices`."""
        return tuple([l.get_slice(qi) for l, qi in zip(self.legs, qindices)])

    def _get_block_shape(self, qindices):
        """Return shape for the block given by qindices."""
        return tuple([(l.slices[qi + 1] - l.slices[qi])
                      for l, qi in zip(self.legs, qindices)])

    def _get_block(self, qindices, insert=False, raise_incomp_q=False):
        """Return the ndarray in ``_data`` representing the block corresponding to `qindices`.

        Parameters
        ----------
        qindices : 1D array of np.intp
            The qindices, for which we need to look in _qdata.
        insert : bool
            If True, insert a new (zero) block, if `qindices` is not existent in ``self._data``.
            Else: just return ``None`` in that case.
        raise_incomp_q : bool
            Raise an IndexError if the charge is incompatible.

        Returns
        -------
        block: ndarray
            The block in ``_data`` corresponding to qindices.
            If `insert`=False and there is not block with qindices, return ``False``.

        Raises
        ------
        IndexError
            If qindices are incompatible with charge and `raise_incomp_q`.
        """
        if not np.all(self._get_block_charge(qindices) == self.qtotal):
            if raise_incomp_q:
                raise IndexError("trying to get block for qindices incompatible with charges")
            return None
        # find qindices in self._qdata
        match = np.argwhere(np.all(self._qdata == qindices, axis=1))[:, 0]
        if len(match) == 0:
            if insert:
                res = np.zeros(self._get_block_shape(qindices), dtype=self.dtype)
                self._data.append(res)
                self._qdata = np.append(self._qdata, [qindices], axis=0)
                self._qdata_sorted = False
                return res
            else:
                return None
        return self._data[match[0]]

    def _bunch(self, bunch_legs):
        """Return copy and bunch the qind for one or multiple legs.

        Parameters
        ----------
        bunch : list of {True, False}
            One entry for each leg, whether the leg should be bunched.

        See also
        --------
        sort_legcharge: public API calling this function.
        """
        cp = self.copy(deep=False)
        # lists for each leg:
        map_qindex = [None] * cp.rank  # array mapping old qindex to new qindex, such that
        # ``new_leg.charges[m_qindex[i]] == old_leg.charges[i]``
        bunch_qindex = [None] * cp.rank  # bool array whether the *new* qindex was bunched
        for li, bunch in enumerate(bunch_legs):
            idx, new_leg = cp.legs[li].bunch()
            cp.legs[li] = new_leg
            # generate entries in map_qindex and bunch_qdindex
            bunch_qindex[li] = ((idx[1:] - idx[:-1]) > 1)
            m_qindex = np.zeros(idx[-1], dtype=np.intp)
            m_qindex[idx[:-1]] = 1
            map_qindex[li] = np.cumsum(m_qindex, axis=0)

        # now map _data and _qdata
        bunched_blocks = {}  # new qindices -> index in new _data
        new_data = []
        new_qdata = []
        for old_block, old_qindices in zip(self._data, self._qdata):
            new_qindices = tuple([m[qi] for m, qi in zip(map_qindex, old_qindices)])
            bunch = any([b[qi] for b, qi in zip(bunch_qindex, new_qindices)])
            if bunch:
                if new_qindices not in bunched_blocks:
                    # create enlarged block
                    bunched_blocks[new_qindices] = len(new_data)
                    # cp has new legs and thus gives the new shape
                    new_block = np.zeros(cp._get_block_shape(new_qindices), dtype=cp.dtype)
                    new_data.append(new_block)
                    new_qdata.append(new_qindices)
                else:
                    new_block = new_data[bunched_blocks[new_qindices]]
                # figure out where to insert the in the new bunched_blocks
                old_slbeg = [l.slices[qi] for l, qi in zip(self.legs, old_qindices)]
                new_slbeg = [l.slices[qi] for l, qi in zip(cp.legs, new_qindices)]
                slbeg = [(o - n) for o, n in zip(old_slbeg, new_slbeg)]
                sl = [slice(beg, beg + l) for beg, l in zip(slbeg, old_block.shape)]
                # insert the old block into larger new block
                new_block[tuple(sl)] = old_block
            else:
                # just copy the old block
                new_data.append(old_block.copy())
                new_qdata.append(new_qindices)
        cp._data = new_data
        cp._qdata = np.array(new_qdata, dtype=np.intp).reshape((len(new_data), self.rank))
        cp._qsorted = False
        return cp

    def _perm_qind(self, p_qind, leg):
        """Apply a permutation `p_qind` of the qindices in leg `leg` to _qdata. In place."""
        # entry ``b`` of of old old._qdata[:, leg] refers to old ``old.legs[leg][b]``.
        # since new ``new.legs[leg][i] == old.legs[leg][p_qind[i]]``,
        # we have new ``new.legs[leg][reverse_sort_perm(p_qind)[b]] == old.legs[leg][b]``
        # thus we replace an entry `b` in ``_qdata[:, leg]``with reverse_sort_perm(q_ind)[b].
        p_qind_r = inverse_permutation(p_qind)
        self._qdata[:, leg] = p_qind_r[self._qdata[:, leg]]  # equivalent to
        # self._qdata[:, leg] = [p_qind_r[i] for i in self._qdata[:, leg]]
        self._qdata_sorted = False

    def _pre_indexing(self, inds):
        """Check if `inds` are valid indices for ``self[inds]`` and replaces Ellipsis by slices.

        Returns
        -------
        only_integer : bool
            Whether all of `inds` are (convertible to) np.intp.
        inds : tuple, len=self.rank
            `inds`, where ``Ellipsis`` is replaced by the correct number of slice(None).
        """
        if type(inds) != tuple:  # for rank 1
            inds = (inds, )
        if len(inds) < self.rank:
            inds = inds + (Ellipsis, )
        if any([(i is Ellipsis) for i in inds]):
            fill = tuple([slice(None)] * (self.rank - len(inds) + 1))
            e = inds.index(Ellipsis)
            inds = inds[:e] + fill + inds[e + 1:]
        if len(inds) > self.rank:
            raise IndexError("too many indices for Array")
        # do we have only integer entries in `inds`?
        try:
            only_int = np.array(inds, dtype=np.intp)
            assert (only_int.shape == (len(inds), ))
        except:
            return False, inds
        else:
            return True, inds

    def _advanced_getitem(self, inds, calc_map_qind=False, permute=True):
        """Calculate self[inds] for non-integer `inds`.

        This function is called by self.__getitem__(inds).
        and from _advanced_setitem_npc with ``calc_map_qind=True``.

        Parameters
        ----------
        inds : tuple
            Indices for the different axes, as returned by :meth:`_pre_indexing`.
        calc_map_qind :
            Whether to calculate and return the additional `map_qind` and `axes` tuple.
        permute :
            If False, don't perform permutations in case one of `inds` is an unsorted index array,
            but consider it as a mask only, ignoring the order of the indices.

        Returns
        -------
        map_qind_part2self : function
            Only returned if `calc_map_qind` is True.
            This function takes qindices from `res` as arguments
            and returns ``(qindices, block_mask)`` such that
            ``res._get_block(part_qindices) = self._get_block(qindices)[block_mask]``.
            permutation are ignored for this.
        permutations : list((int, 1D array(int)))
            Only returned if `calc_map_qind` is True.
            Collects (axes, permutation) applied to `res` *after* `take_slice` and `iproject`.
        res : :class:`Array`
            A copy with the data ``self[inds]``.
        """
        # non-integer inds -> slicing / projection
        slice_inds = []  # arguments for `take_slice`
        slice_axes = []
        project_masks = []  # arguments for `iproject`
        project_axes = []
        permutations = []  # [axis, mask] for all axes for which we need to call `permute`
        for a, i in enumerate(inds):
            if isinstance(i, slice):
                if i != slice(None):
                    m = np.zeros(self.shape[a], dtype=np.bool_)
                    m[i] = True
                    project_masks.append(m)
                    project_axes.append(a)
                    if i.step is not None and i.step < 0:
                        permutations.append((a, np.arange(np.count_nonzero(m),
                                                          dtype=np.intp)[::-1]))
            else:
                try:
                    iter(i)
                except:  # not iterable: single index
                    slice_inds.append(int(i))
                    slice_axes.append(a)
                else:  # iterable
                    i = np.asarray(i)
                    project_masks.append(i)
                    project_axes.append(a)
                    if i.dtype != np.bool_:  # should be integer indexing
                        perm = np.argsort(i)  # check if `i` is sorted
                        if np.any(perm != np.arange(len(perm))):
                            # np.argsort(i) gives the reverse permutation, so reverse it again.
                            # In that way, we get the permuation within the projected indices.
                            permutations.append((a, inverse_permutation(perm)))
        res = self.take_slice(slice_inds, slice_axes)
        res_axes = np.cumsum([(a not in slice_axes) for a in range(self.rank)]) - 1
        p_map_qinds, p_masks = res.iproject(project_masks, [res_axes[p] for p in project_axes])
        permutations = [(res_axes[a], p) for a, p in permutations]
        if permute:
            for a, perm in permutations:
                res = res.permute(perm, a)
        if not calc_map_qind:
            return res
        part2self = self._advanced_getitem_map_qind(inds, slice_axes, slice_inds, project_axes,
                                                    p_map_qinds, p_masks, res_axes)
        return part2self, permutations, res

    def _advanced_getitem_map_qind(self, inds, slice_axes, slice_inds, project_axes, p_map_qinds,
                                   p_masks, res_axes):
        """Generate a function mapping from qindices of `self[inds]` back to qindices of self.

        This function is called only by `_advanced_getitem(calc_map_qind=True)`
        to obtain the function `map_qind_part2self`,
        which in turn in needed in `_advanced_setitem_npc` for ``self[inds] = other``.
        This function returns a function `part2self`, see doc string in the source for details.
        Note: the function ignores permutations introduced by `inds` - they are handled separately.
        """
        map_qinds = [None] * self.rank
        map_blocks = [None] * self.rank
        for a, i in zip(slice_axes, slice_inds):
            qi, within_block = self.legs[a].get_qindex(inds[a])
            map_qinds[a] = qi
            map_blocks[a] = within_block
        for a, m_qind in zip(project_axes, p_map_qinds):
            map_qinds[a] = np.nonzero(m_qind >= 0)[0]  # revert m_qind
        # keep_axes = neither in slice_axes nor in project_axes
        keep_axes = [a for a, i in enumerate(map_qinds) if i is None]
        not_slice_axes = sorted(project_axes + keep_axes)
        bsizes = [l._get_block_sizes() for l in self.legs]

        def part2self(part_qindices):
            """Given `part_qindices` of ``res = self[inds]``,
            return (`qindices`, `block_mask`) such that
            ``res._get_block(part_qindices) == self._get_block(qindices)``.
            """
            qindices = map_qinds[:]  # copy
            block_mask = map_blocks[:]  # copy
            for a in keep_axes:
                qindices[a] = qi = part_qindices[res_axes[a]]
                block_mask[a] = np.arange(bsizes[a][qi], dtype=np.intp)
            for a, bmask in zip(project_axes, p_masks):
                old_qi = part_qindices[res_axes[a]]
                qindices[a] = map_qinds[a][old_qi]
                block_mask[a] = bmask[old_qi]
            # advanced indexing in numpy is tricky ^_^
            # np.ix_ can't handle integer entries reducing the dimension.
            # we have to call it only on the entries with arrays
            ix_block_mask = np.ix_(*[block_mask[a] for a in not_slice_axes])
            # and put the result back into block_mask
            for a, bm in zip(not_slice_axes, ix_block_mask):
                block_mask[a] = bm
            return qindices, tuple(block_mask)

        return part2self

    def _advanced_setitem_npc(self, inds, other):
        """Self[inds] = other for non-integer `inds` and :class:`Array` `other`.

        This function is called by self.__setitem__(inds, other)."""
        # suppress warning if we project a pipe
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            map_part2self, permutations, self_part = self._advanced_getitem(
                inds, calc_map_qind=True, permute=False)
        # permuations are ignored by map_part2self.
        # instead of figuring out permuations in self, apply the *reversed* permutations ot other
        for ax, perm in permutations:
            other = other.permute(inverse_permutation(perm), ax)
        # now test compatibility of self_part with `other`
        if self_part.rank != other.rank:
            raise IndexError("wrong number of indices")
        for pl, ol in zip(self_part.legs, other.legs):
            pl.test_contractible(ol.conj())
        if np.any(self_part.qtotal != other.qtotal):
            raise ValueError("wrong charge for assinging self[inds] = other")
        # note: a block exists in self_part, if and only if its extended version exists in self.
        # by definition, non-existent blocks in `other` are zero.
        # instead of checking which blocks are non-existent,
        # we first set self[inds] completely to zero
        for p_qindices in self_part._qdata:
            qindices, block_mask = map_part2self(p_qindices)
            block = self._get_block(qindices)
            block[block_mask] = 0.  # overwrite data in self
        # now we copy blocks from other
        for o_block, o_qindices in zip(other._data, other._qdata):
            qindices, block_mask = map_part2self(o_qindices)
            block = self._get_block(qindices, insert=True)
            block[block_mask] = o_block  # overwrite data in self
        self.ipurge_zeros(0.)  # remove blocks identically zero

    def _combine_legs_make_pipes(self, combine_legs, pipes, qconj):
        """Argument parsing for :meth:`combine_legs`: make missing pipes.

        Generates missing pipes & checks compatibility for provided pipes."""
        npipes = len(combine_legs)
        # default arguments for pipes and qconj
        if pipes is None:
            pipes = [None] * npipes
        elif len(pipes) != npipes:
            raise ValueError("wrong len of `pipes`")
        qconj = list(to_iterable(qconj if qconj is not None else +1))
        if len(qconj) == 1 and 1 < npipes:
            qconj = [qconj[0]] * npipes  # same qconj for all pipes
        if len(qconj) != npipes:
            raise ValueError("wrong len of `qconj`")

        pipes = list(pipes)
        # make pipes as necessary
        for i, pipe in enumerate(pipes):
            if pipe is None:
                pipes[i] = self.make_pipe(axes=combine_legs[i], qconj=qconj[i])
            else:
                # test for compatibility
                legs = [self.get_leg(a) for a in combine_legs[i]]
                if pipe.nlegs != len(legs):
                    raise ValueError("pipe has wrong number of legs")
                if legs[0].qconj != pipe.legs[0].qconj:
                    pipes[i] = pipe = pipe.conj()  # need opposite qind
                for self_leg, pipe_leg in zip(legs, pipe.legs):
                    self_leg.test_equal(pipe_leg)
        return pipes

    def _combine_legs_new_axes(self, combine_legs, new_axes):
        """Figure out new_axes and how legs have to be transposed."""
        all_combine_legs = np.concatenate(combine_legs)
        non_combined_legs = np.array([a for a in range(self.rank) if a not in all_combine_legs])
        if new_axes is None:  # figure out default new_legs
            first_cl = np.array([cl[0] for cl in combine_legs])
            new_axes = [(np.sum(non_combined_legs < a) + np.sum(first_cl < a)) for a in first_cl]
        else:  # test compatibility
            if len(new_axes) != len(combine_legs):
                raise ValueError("wrong len of `new_axes`")
            new_rank = len(combine_legs) + len(non_combined_legs)
            for i, a in enumerate(new_axes):
                if a < 0:
                    new_axes[i] = a + new_rank
                elif a >= new_rank:
                    raise ValueError("new_axis larger than the new number of legs")
        transp = [[a] for a in non_combined_legs]
        for s in np.argsort(new_axes):
            transp.insert(new_axes[s], list(combine_legs[s]))
        transp = sum(transp, [])  # flatten: [a] + [b] = [a, b]
        return new_axes, tuple(transp)

    cdef Array _combine_legs_worker(Array self,
                                    list combine_legs,
                                    list new_axes,
                                    list pipes):
        """The main work of combine_legs: create a copy and reshape the data blocks.

        Assumes standard form of parameters.

        Parameters
        ----------
        combine_legs : list(1D np.array)
            Axes of self which are collected into pipes.
        new_axes : 1D array
            The axes of the pipes in the new array. Ascending.
        pipes : list of :class:`LegPipe`
            All the correct output pipes, already generated.

        Returns
        -------
        res : :class:`Array`
            Copy of self with combined legs.
        """
        all_combine_legs = np.concatenate(combine_legs)
        # non_combined_legs: axes of self which are not in combine_legs
        cdef np.ndarray[np.intp_t, ndim=1] non_combined_legs = np.array(
            [a for a in range(self.rank) if a not in all_combine_legs], dtype=np.intp)
        legs = [self.legs[i] for i in non_combined_legs]
        for na, p in zip(new_axes, pipes):  # not reversed
            legs.insert(na, p)
        cdef Array res = self.copy(deep=False)
        res.legs = legs
        res._set_shape()
        if self.stored_blocks == 0:
            res._data = []
            res._qdata = np.empty((0, res.rank), dtype=np.intp)
            return res
        non_new_axes_ = [i for i in range(res.rank) if i not in new_axes]
        cdef np.ndarray[np.intp_t, ndim=1] non_new_axes = np.array(non_new_axes_, dtype=np.intp)

        # map `self._qdata[:, combine_leg]` to `pipe.q_map` indices for each new pipe
        qmap_inds = [
            p._map_incoming_qind(self._qdata[:, cl]) for p, cl in zip(pipes, combine_legs)
        ]

        # get new qdata
        cdef np.ndarray[np.intp_t, ndim=2] qdata = np.empty((self.stored_blocks, res.rank),
                                                            dtype=np.intp)
        qdata[:, non_new_axes] = self._qdata[:, non_combined_legs]
        for na, p, qmap_ind in zip(new_axes, pipes, qmap_inds):
            np.take(
                p.q_map[:, 2],  # column 2 of q_map maps to qindex of the pipe
                qmap_ind,
                out=qdata[:, na])  # write the result directly into qdata
        # now we have probably many duplicate rows in qdata,
        # since for the pipes many `qmap_ind` map to the same `qindex`
        # find unique entries by sorting qdata
        sort = np.lexsort(qdata.T)
        qdata_s = qdata[sort]
        old_data = [self._data[s] for s in sort]
        qmap_inds = [qm[sort] for qm in qmap_inds]
        # divide into parts, which give a single new block
        cdef np.ndarray[np.intp_t, ndim=1] diffs = _c_find_row_differences(qdata_s)
        # including the first and last row

        # now the hard part: map data
        cdef list data = []
        cdef list slices = [slice(None)] * res.rank  # for selecting the slices in the new blocks
        # iterate over ranges of equal qindices in qdata_s
        cdef np.ndarray new_block, old_block #, new_block_view # TODO: shape doesn't work...
        cdef np.ndarray[np.intp_t, ndim=1] qindices
        cdef int beg, end, bi, j, old_data_idx, qi
        cdef np.ndarray[np.intp_t, ndim=2] q_map
        cdef tuple sl
        cdef int npipes = len(combine_legs)
        for bi in range(diffs.shape[0]-1):
            beg = diffs[bi]
            end = diffs[bi+1]
            qindices = qdata_s[beg]
            new_block = np.zeros(res._get_block_shape(qindices), dtype=res.dtype)
            data.append(new_block)
            # copy blocks
            for old_data_idx in range(beg, end):
                for j in range(npipes):
                    q_map = pipes[j].q_map
                    qi = qmap_inds[j][old_data_idx]
                    slices[new_axes[j]] = slice(q_map[qi, 0], q_map[qi, 1])
                sl = tuple(slices)
                # reshape block while copying
                new_block_view = new_block[sl]
                old_block = old_data[old_data_idx].reshape(new_block_view.shape)
                np.copyto(new_block_view, old_block, casting='no')
        res._qdata = qdata_s[diffs[:-1]]  # (keeps the dimensions)
        res._qdata_sorted = True
        res._data = data
        return res

    cdef Array _split_legs_worker(Array self, list split_axes_, float cutoff):
        """The main work of split_legs: create a copy and reshape the data blocks.

        Called by :meth:`split_legs`. Assumes that the corresponding legs are LegPipes.
        """
        # calculate mappings of axes
        # in self
        cdef np.ndarray[np.intp_t, ndim=1] split_axes = np.sort(split_axes_)
        cdef int a, i, j, nsplit=split_axes.shape[0]
        pipes = [self.legs[a] for a in split_axes]
        cdef np.ndarray[np.intp_t, ndim=1] nonsplit_axes = np.array(
            [i for i in range(self.rank) if i not in split_axes], dtype=np.intp)
        # in result
        cdef np.ndarray[np.intp_t, ndim=1] new_nonsplit_axes = np.arange(self.rank, dtype=np.intp)
        for a in split_axes:
            new_nonsplit_axes[a + 1:] += self.legs[a].nlegs - 1
        cdef np.ndarray[np.intp_t, ndim=1] new_split_axes_first = new_nonsplit_axes[split_axes]
        #    = the first leg for splitted pipes
        cdef list new_split_slices = [slice(a, a + p.nlegs) for a, p in zip(new_split_axes_first, pipes)]
        new_nonsplit_axes = new_nonsplit_axes[nonsplit_axes]

        cdef Array res = self.copy(deep=False)
        for a in reversed(split_axes):
            res.legs[a:a + 1] = res.legs[a].legs  # replace pipes with saved original legs
        res._set_shape()

        # get new qdata by stacking columns
        tmp_qdata = np.empty((self.stored_blocks, res.rank), dtype=np.intp)
        tmp_qdata[:, new_nonsplit_axes] = self._qdata[:, nonsplit_axes]
        tmp_qdata[:, new_split_axes_first] = self._qdata[:, split_axes]

        # now split the blocks
        cdef list data = []
        cdef list qdata = []  # rows of the new qdata
        cdef np.ndarray[np.intp_t, ndim=1] new_block_shape = np.empty(res.rank, dtype=np.intp)
        cdef np.ndarray[np.intp_t, ndim=1] qdata_row, qm
        cdef list block_slice = [slice(None)] * self.rank
        cdef list qmap_slices = [None] * nsplit
        cdef slice sl
        cdef LegPipe pipe
        cdef LegCharge leg
        cdef np.ndarray old_block, new_block

        for old_block, qdata_row in zip(self._data, tmp_qdata):
            for j in range(nonsplit_axes.shape[0]):
                new_block_shape[new_nonsplit_axes[j]] = old_block.shape[nonsplit_axes[j]]
            for j in range(nsplit):
                pipe = pipes[j]
                qmap_slices[j] = pipe.q_map_slices[qdata_row[new_split_axes_first[j]]]
            for qmap_rows in itertools.product(*qmap_slices):
                for i in range(nsplit):
                    qm = qmap_rows[i]
                    a = new_split_axes_first[i]
                    pipe = pipes[i]
                    for j in range(pipe.nlegs):
                        qi = qm[3+j]
                        qdata_row[a+j] = qi
                        leg = pipe.legs[j]
                        new_block_shape[a+j] = leg.slices[qi+1] - leg.slices[qi]
                    block_slice[split_axes[i]] = slice(qm[0], qm[1])
                new_block = old_block[tuple(block_slice)].reshape(new_block_shape)
                # all charges are compatible by construction, but some might be zero
                if np.any(np.abs(new_block) > cutoff):
                    data.append(new_block.copy())  # copy, not view
                    qdata.append(qdata_row.copy())  # copy! qdata_row is changed afterwards...
        if len(data) > 0:
            res._qdata = np.array(qdata, dtype=np.intp)
            res._qdata_sorted = False
        else:
            res._qdata = np.empty((0, res.rank), dtype=np.intp)
            res._qdata_sorted = True
        res._data = data
        return res

    @staticmethod
    def _combine_leg_labels(labels):
        """Generate label for legs combined in a :class:`LegPipe`.

        Examples
        --------
        >>> self._combine_leg_labels(['a', 'b', '(c.d)'])
        '(a.b.(c.d))'
        """
        return '(' + '.'.join(labels) + ')'

    @staticmethod
    def _split_leg_label(label_, count):
        """Revert the combination of labels performed in :meth:`combine_leg_labels`.

        Return a list of labels corresponding to the original labels before 'combine_legs'.
        Test that it splits into `count` labels.

        Examples
        --------
        >>> self._split_leg_label('(a.b.(c.d))', 3)
        ['a', 'b', '(c.d)']
        """
        if label_ is None:
            return [None] * count
        cdef str label = label_
        if label[0] != '(' or label[-1] != ')':
            warnings.warn("split leg with label not in Form '(...)': " + label)
            return [None] * count
        beg = 1
        depth = 0  # number of non-closed '(' to the left
        res = []
        for i in range(1, len(label) - 1):
            c = label[i]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
            elif c == '.' and depth == 0:
                res.append(label[beg:i])
                beg = i + 1
        res.append(label[beg:i + 1])
        if len(res) != count:
            raise ValueError("wrong number of splitted labels.")
        for i in range(len(res)):
            if res[i][0] == '?':
                res[i] = None
        return res

    @staticmethod
    def _conj_leg_label(label):
        """Conjugate a leg `label`.

        Examples
        --------
        >>> self._conj_leg_labels('a')
        'a*'
        >>> self._conj_leg_labels('a*')
        'a'
        >>> self._conj_leg_labels('(a.(b*.c))')
        '(a*.(b.c*))'
        """
        # first insert '*' after each label, taking into account recursion of LegPipes
        res = []
        beg = 0
        for i in range(1, len(label)):
            if label[i - 1] != ')' and label[i] in '.)':
                res.append(label[beg:i])
                beg = i
        res.append(label[beg:])
        label = '*'.join(res)
        if label[-1] != ')':
            label += '*'
        # remove '**' entries
        return label.replace('**', '')

    def _imake_contiguous(self, order='C'):
        """Make each of the blocks contigous in memory.

        Might speed up subsequent tensordot & co by fixing the memory layout to contigous blocks.
        (No need to call it manually: it's called from tensordot anyways!)"""
        if order == 'C':
            self._data = [np.ascontiguousarray(t) for t in self._data]
        elif order == 'F':
            self._data = [np.asfortranarray(t) for t in self._data]
        else:
            raise ValueError("unknown order")
        return self


# functions ====================================================================


def zeros(legcharges, dtype=np.float64, qtotal=None):
    """Create a npc array full of zeros (with no _data).

    This is just a wrapper around ``Array(...)``,
    detailed documentation can be found in the class doc-string of :class:`Array`."""
    return Array(legcharges, dtype, qtotal)


def eye_like(a, axis=0):
    """Return an identity matrix contractible with the leg `axis` of the :class:`Array` `a`."""
    axis = a.get_leg_index(axis)
    return diag(1., a.legs[axis])


def diag(s, leg, dtype=None):
    """Returns a square, diagonal matrix of entries `s`.

    The resulting matrix has legs ``(leg, leg.conj())`` and charge 0.

    Parameters
    ----------
    s : scalar | 1D array
        The entries to put on the diagonal. If scalar, all diagonal entries are the same.
    leg : :class:`LegCharge`
        The first leg of the resulting matrix.
    dtype : None | type
        The data type to be used for the result. By default, use dtype of `s`.

    Returns
    -------
    diagonal : :class:`Array`
        A square matrix with diagonal entries `s`.

    See also
    --------
    :meth:`Array.scale_axis` : similar as ``tensordot(diag(s), ...)``, but faster.
    """
    s = np.asarray(s, dtype)
    scalar = (s.ndim == 0)
    if not scalar and len(s) != leg.ind_len:
        raise ValueError("len(s)={0:d} not equal to leg.ind_len={1:d}".format(len(s), leg.ind_len))
    res = Array((leg, leg.conj()), s.dtype)  # default charge is 0
    # qdata = [[0, 0], [1, 1], ....]
    res._qdata = np.arange(leg.block_number, dtype=np.intp)[:, np.newaxis] * np.ones(2, np.intp)
    # ``res._qdata_sorted = True`` was already set
    if scalar:
        res._data = [np.diag(s * np.ones(size, dtype=s.dtype)) for size in leg._get_block_sizes()]
    else:
        res._data = [np.diag(s[leg.get_slice(qi)]) for qi in range(leg.block_number)]
    return res


def concatenate(arrays, axis=0, copy=True):
    """Stack arrays along a given axis, similar as np.concatenate.

    Stacks the qind of the array, without sorting/blocking.
    Labels are inherited from the first array only.

    Parameters
    ----------
    arrays : iterable of :class:`Array`
        The arrays to be stacked. They must have the same shape and charge data
        except on the specified axis.
    axis : int | str
        Leg index or label of the first array. Defines the axis along which the arrays are stacked.
    copy : bool
        Whether to copy the data blocks.

    Returns
    -------
    stacked : :class:`Array`
        Concatenation of the given `arrays` along the specified axis.

    See also
    --------
    :meth:`Array.sort_legcharge` : can be used to block by charges along the axis.
    """
    arrays = list(arrays)
    cdef Array res = arrays[0].zeros_like()
    res.labels = arrays[0].labels.copy()
    axis = res.get_leg_index(axis)
    not_axis = list(range(res.rank))
    del not_axis[axis]
    not_axis = np.array(not_axis, dtype=np.intp)
    # test for compatibility
    for a in arrays:
        if a.shape[:axis] != res.shape[:axis] or a.shape[axis + 1:] != res.shape[axis + 1:]:
            raise ValueError("wrong shape " + repr(a))
        if a.chinfo != res.chinfo:
            raise ValueError("wrong ChargeInfo")
        if a.qtotal != res.qtotal:
            raise ValueError("wrong qtotal")
        for l in not_axis:
            a.legs[l].test_equal(res.legs[l])
    dtype = res.dtype = np.find_common_type([a.dtype for a in arrays], [])
    # stack the data
    res_axis_bl_sizes = []
    res_axis_charges = []
    res_qdata = []
    res_data = []
    qind_shift = 0  # sum of previous `block_number`
    axis_qconj = res.legs[axis].qconj
    for a in arrays:
        leg = a.legs[axis]
        res_axis_bl_sizes.append(leg._get_block_sizes())
        charges = leg.charges if leg.qconj == axis_qconj else res.chinfo.make_valid(-leg.charges)
        res_axis_charges.append(charges)
        qdata = a._qdata.copy()
        qdata[:, axis] += qind_shift
        res_qdata.append(qdata)
        if copy:
            res_data.extend([np.array(t, dtype) for t in a._data])
        else:
            res_data.extend([np.asarray(t, dtype) for t in a._data])
        qind_shift += leg.block_number
    res_axis_slices = np.append([0], np.cumsum(np.concatenate(res_axis_bl_sizes)))
    res_axis_charges = np.concatenate(res_axis_charges, axis=0)
    res.legs[axis] = LegCharge.from_qind(res.chinfo, res_axis_slices, res_axis_charges, axis_qconj)
    res._set_shape()
    res._qdata = np.concatenate(res_qdata, axis=0)
    res._qdata_sorted = False
    res._data = res_data
    res.test_sanity()
    return res


def grid_concat(grid, axes, copy=True):
    """Given an np.array of npc.Arrays, performs a multi-dimensional concatentation along 'axes'.

    Stacks the qind of the array, *without* sorting/blocking.

    Parameters
    ----------
    grid : array_like of :class:`Array`
        The grid of arrays.
    axes : list of int
        The axes along which to concatenate the arrays,  same len as the dimension of the grid.
        Concatenate arrays of the `i`th axis of the grid along the axis ``axes[i]``
    copy : bool
        Whether the _data blocks are copied.

    Examples
    --------
    Assume we have rank 2 Arrays ``A, B, C, D`` of shapes
    ``(1, 2), (1, 4), (3, 2), (3, 4)`` sharing the legs of equal sizes.
    Then the following grid will result in a ``(1+3, 2+4)`` shaped array:

    >>> g = grid_concat([[A, B], [C, D]], axes=[0, 1])
    >>> g.shape
    (4, 6)

    If ``A, B, C, D`` were rank 4 arrays, with the first and last leg as before, and sharing
    *common* legs ``1`` and ``2``, then you would get a rank-4 array:

    >>> g = grid_concat([[A, B], [C, D]], axes=[0, 3])
    >>> g.shape
    (4, 6)

    See also
    --------
    :meth:`Array.sort_legcharge` : can be used to block by charges.
    """
    if not isinstance(grid, np.ndarray):
        grid = np.array(grid, dtype=np.object)
    if grid.ndim < 1 or grid.ndim != len(axes):
        raise ValueError("grid has wrong dimension")
    # Simple recursion on ndim. Copy only required on first go.
    if grid.ndim > 1:
        grid = [grid_concat(b, axes=axes[1:], copy=copy) for b in grid]
        copy = False
    grid = concatenate(grid, axes[0], copy=copy)
    return grid


def grid_outer(grid, grid_legs, qtotal=None):
    """Given an np.array of npc.Arrays, return the corresponding higher-dimensional Array.

    Parameters
    ----------
    grid : array_like of {:class:`Array` | None}
        The grid gives the first part of the axes of the resulting array.
        Entries have to have all the same shape and charge-data, giving the remaining axes.
        ``None`` entries in the grid are interpreted as zeros.
    grid_legs : list of :class:`LegCharge`
        One LegCharge for each dimension of the grid along the grid.
    qtotal : charge
        The total charge of the Array.
        By default (``None``), derive it out from a non-trivial entry of the grid.

    Returns
    -------
    res : :class:`Array`
        An Array with shape ``grid.shape + nontrivial_grid_entry.shape``.
        Constructed such that ``res[idx] == grid[idx]`` for any index ``idx`` of the `grid`
        the `grid` entry is not trivial (``None``).

    See also
    --------
    detect_grid_outer_legcharge : can calculate one missing :class:`LegCharge` of the grid.


    Examples
    --------
    A typical use-case for this function is the generation of an MPO.
    Say you have npc.Arrays ``Splus, Sminus, Sz``, each with legs ``[phys.conj(), phys]``.
    Further, you have to define appropriate LegCharges `l_left` and `l_right`.
    Then one 'matrix' of the MPO for a nearest neighbour Heisenberg Hamiltonian could look like:

    >>> Id = np.eye_like(Sz)
    >>> W_mpo = grid_outer([[Id, Splus, Sminus, Sz, None],
    ...                     [None, None, None, None, J*Sminus],
    ...                     [None, None, None, None, J*Splus],
    ...                     [None, None, None, None, J*Sz],
    ...                     [None, None, None, None, Id]],
    ...                    leg_charges=[l_left, l_right])
    >>> W_mpo.shape
    (5, 5, 2, 2)
    """
    grid_shape, entries = _nontrivial_grid_entries(grid)
    if len(grid_shape) != len(grid_legs):
        raise ValueError("wrong number of grid_legs")
    if grid_shape != tuple([l.ind_len for l in grid_legs]):
        raise ValueError("grid shape incompatible with grid_legs")
    idx, entry = entries[0]  # first non-trivial entry
    chinfo = entry.chinfo
    dtype = np.find_common_type([e.dtype for _, e in entries], [])
    legs = list(grid_legs) + entry.legs
    labels = tuple(entry.get_leg_labels())
    if qtotal is None:
        # figure out qtotal from first non-zero entry
        grid_charges = [l.get_charge(l.get_qindex(i)[0]) for i, l in zip(idx, grid_legs)]
        qtotal = chinfo.make_valid(np.sum(grid_charges + [entry.qtotal], axis=0))
    else:
        qtotal = chinfo.make_valid(qtotal)
    res = Array(legs, dtype, qtotal)
    # main work: iterate over all non-trivial entries to fill `res`.
    for idx, entry in entries:
        res[idx] = entry  # insert the values with Array.__setitem__ partial slicing.
        if labels is not None and tuple(entry.get_leg_labels()) != labels:
            labels = None
    if labels is not None:
        res.iset_leg_labels([None] * len(grid_shape) + list(labels))
    res.test_sanity()
    return res


def detect_grid_outer_legcharge(grid, grid_legs, qtotal=None, qconj=1, bunch=False):
    """Derive a LegCharge for a grid used for :func:`grid_outer`.

    Note: The resulting LegCharge is *not* bunched.

    Parameters
    ----------
    grid : array_like of {:class:`Array` | None}
        The grid as it will be given to :func:`grid_outer`.
    grid_legs : list of {:class:`LegCharge` | None}
        One LegCharge for each dimension of the grid, except for one entry which is ``None``.
        This missing entry is to be calculated.
    qtotal : charge
        The desired total charge of the array. Defaults to 0.

    Returns
    -------
    new_grid_legs : list of :class:`LegCharge`
        A copy of the given `grid_legs` with the ``None`` replaced by a compatible LegCharge.
        The new LegCharge is neither bunched nor sorted!

    See also
    --------
    detect_legcharge : similar functionality for a flat numpy array instead of a grid.
    """
    grid_shape, entries = _nontrivial_grid_entries(grid)
    if len(grid_shape) != len(grid_legs):
        raise ValueError("wrong number of grid_legs")
    if any([s != l.ind_len for s, l in zip(grid_shape, grid_legs) if l is not None]):
        raise ValueError("grid shape incompatible with grid_legs")
    idx, entry = entries[0]  # first non-trivial entry
    chinfo = entry.chinfo
    axis = [a for a, l in enumerate(grid_legs) if l is None]
    if len(axis) > 1:
        raise ValueError("can only derive one grid_leg")
    axis = axis[0]
    grid_legs = list(grid_legs)
    qtotal = chinfo.make_valid(qtotal)  # charge 0, if qtotal is not set.
    qflat = [None] * grid_shape[axis]
    for idx, entry in entries:
        grid_charges = [
            l.get_charge(l.get_qindex(i)[0]) for a, (i, l) in enumerate(zip(idx, grid_legs))
            if a != axis
        ]
        qflat_entry = chinfo.make_valid(qtotal - entry.qtotal - np.sum(grid_charges, axis=0))
        i = idx[axis]
        if qflat[i] is None:
            qflat[i] = qflat_entry
        elif np.any(qflat[i] != qflat_entry):
            raise ValueError("different grid entries lead to different charges at index " + str(i))
    if any([q is None for q in qflat]):
        raise ValueError("can't derive flat charge for all indices:" + str(qflat))
    grid_legs[axis] = LegCharge.from_qflat(chinfo,
                                           chinfo.make_valid(qconj * np.array(qflat)), qconj)
    return grid_legs


def detect_qtotal(flat_array, legcharges, cutoff=None):
    """Returns the total charge (w.r.t `legs`) of first non-zero sector found in `flat_array`.

    Parameters
    ----------
    flat_array : array
        The flat numpy array from which you want to detect the charges.
    legcharges : list of :class:`LegCharge`
        For each leg the LegCharge.
    cutoff : float
        Blocks with ``np.max(np.abs(block)) > cutoff`` are considered as zero.
        Defaults to :data:`QCUTOFF`.

    Returns
    -------
    qtotal : charge
        The total charge fo the first non-zero (i.e. > cutoff) charge block.

    See also
    --------
    detect_legcharge : detects the charges of one missing LegCharge if `qtotal` is known.
    detect_grid_outer_legcharge : similar functionality if the flat array is given by a 'grid'.
    """
    if cutoff is None:
        cutoff = QCUTOFF
    chinfo = legcharges[0].chinfo
    test_array = zeros(legcharges)  # Array prototype with correct charges
    for qindices in test_array._iter_all_blocks():
        sl = test_array._get_block_slices(qindices)
        if np.any(np.abs(flat_array[sl]) > cutoff):
            return test_array._get_block_charge(qindices)
    warnings.warn("can't detect total charge: no entry larger than cutoff. Return 0 charge.")
    return chinfo.make_valid()


def detect_legcharge(flat_array, chargeinfo, legcharges, qtotal=None, qconj=+1, cutoff=None):
    """Calculate a missing `LegCharge` by looking for nonzero entries of a flat array.

    Parameters
    ----------
    flat_array : ndarray
        A flat array, in which we look for non-zero entries.
    chargeinfo : :class:`~tenpy.linalg.charges.ChargeInfo`
        The nature of the charge.
    legcharges : list of :class:`LegCharge`
        One LegCharge for each dimension of flat_array, except for one entry which is ``None``.
        This missing entry is to be calculated.
    qconj : {+1, -1}
        `qconj` for the new calculated LegCharge.
    qtotal : charges
        Desired total charge of the array. Defaults to zeros.
    cutoff : float
        Blocks with ``np.max(np.abs(block)) > cutoff`` are considered as zero.
        Defaults to :data:`QCUTOFF`.

    Returns
    -------
    new_legcharges : list of :class:`LegCharge`
        A copy of the given `legcharges` with the ``None`` replaced by a compatible LegCharge.
        The new legcharge is 'bunched', but not sorted!

    See also
    --------
    detect_grid_outer_legcharge : similar functionality if the flat array is given by a 'grid'.
    detect_qtotal : detects the total charge, if all legs are known.
    """
    flat_array = np.asarray(flat_array)
    legs = list(legcharges)
    if cutoff is None:
        cutoff = QCUTOFF
    if flat_array.ndim != len(legs):
        raise ValueError("wrong number of grid_legs")
    if any([s != l.ind_len for s, l in zip(flat_array.shape, legs) if l is not None]):
        raise ValueError("array shape incompatible with legcharges")
    axis = [a for a, l in enumerate(legs) if l is None]
    if len(axis) > 1:
        raise ValueError("can only derive charges for one leg.")
    axis = axis[0]
    axis_len = flat_array.shape[axis]
    if chargeinfo.qnumber == 0:
        legs[axis] = LegCharge.from_trivial(axis_len, chargeinfo, qconj=qconj)
        return legs
    qtotal = chargeinfo.make_valid(qtotal)  # charge 0, if qtotal is not set.
    legs_known = legs[:axis] + legs[axis + 1:]
    qflat = np.empty([axis_len, chargeinfo.qnumber], dtype=QTYPE)
    for i in range(axis_len):
        A_i = np.take(flat_array, i, axis=axis)
        qflat[i] = detect_qtotal(A_i, legs_known, cutoff)
    qflat = chargeinfo.make_valid((qtotal - qflat) * qconj)
    legs[axis] = LegCharge.from_qflat(chargeinfo, qflat, qconj).bunch()[1]
    return legs


def trace(a, leg1=0, leg2=1):
    """Trace of `a`, summing over leg1 and leg2.

    Requires that the contracted legs are contractible (i.e. have opposite charges).
    Labels are inherited from `a`.

    Parameters
    ----------
    leg1, leg2: str|int
        The leg label or index for the two legs which should be contracted (i.e. summed over).

    Returns
    -------
    traced : :class:`Array` | ``a.dtype``
        A scalar if ``a.rank == 2``, else an :class:`Array` of rank ``a.rank - 2``.
        Equivalent to ``sum([a.take_slice([i, i], [leg1, leg2]) for i in range(a.shape[leg1])])``.
    """
    ax1, ax2 = a.get_leg_indices([leg1, leg2])
    if ax1 == ax2:
        raise ValueError("leg1 = {0!r} == leg2 = {1!r} ???".format(leg1, leg2))
    a.legs[ax1].test_contractible(a.legs[ax2])
    if a.rank == 2:
        # full contraction: ax1, ax2 = 0, 1 or vice versa
        res_scalar = a.dtype.type(0.)
        for qdata_row, block in zip(a._qdata, a._data):
            if qdata_row[0] == qdata_row[1]:
                res_scalar += np.trace(block)
        return res_scalar
    # non-complete contraction
    keep = np.array([ax for ax in range(a.rank) if ax != ax1 and ax != ax2], dtype=np.intp)
    legs = [a.legs[ax] for ax in keep]
    cdef Array res = Array(legs, a.dtype, a.qtotal)
    if a.stored_blocks > 0:
        res_data = {}  # dictionary qdata_row -> block
        for qdata_row, block in zip(a._qdata, a._data):
            if qdata_row[ax1] != qdata_row[ax2]:
                continue  # not on the diagonal => doesn't contribute
            new_qdata_row = tuple(qdata_row[keep])
            if new_qdata_row in res_data:
                res_data[new_qdata_row] += np.trace(block, axis1=ax1, axis2=ax2)
            else:
                res_data[new_qdata_row] = np.trace(block, axis1=ax1, axis2=ax2)
        if len(res_data) > 0:
            res._data = list(res_data.values())
            res._qdata = np.array(list(res_data.keys()), np.intp)
            res._qdata_sorted = False
    # labels
    a_labels = a.get_leg_labels()
    res.iset_leg_labels([a_labels[ax] for ax in keep])
    return res


def outer(a, b):
    """Forms the outer tensor product, equivalent to ``tensordot(a, b, axes=0)``.

    Labels are inherited from `a` and `b`. In case of a collision (same label in both `a` and `b`),
    they are both dropped.

    Parameters
    ----------
    a, b : :class:`Array`
        The arrays for which to form the product.

    Returns
    -------
    c : :class:`Array`
        Array of rank ``a.rank + b.rank`` such that (for ``Ra = a.rank; Rb = b.rank``)::

            c[i_1, ..., i_Ra, j_1, ... j_R] = a[i_1, ..., i_Ra] * b[j_1, ..., j_rank_b]
    """
    if a.chinfo != b.chinfo:
        raise ValueError("different ChargeInfo")
    dtype = np.find_common_type([a.dtype, b.dtype], [])
    qtotal = a.chinfo.make_valid(a.qtotal + b.qtotal)
    cdef Array res = Array(a.legs + b.legs, dtype, qtotal)

    # fill with data
    qdata_a = a._qdata
    qdata_b = b._qdata
    grid = np.mgrid[:len(qdata_a), :len(qdata_b)].T.reshape(-1, 2)
    # grid is lexsorted like qdata, with rows as all combinations of a/b block indices.
    qdata_res = np.empty((len(qdata_a) * len(qdata_b), res.rank), dtype=np.intp)
    qdata_res[:, :a.rank] = qdata_a[grid[:, 0]]
    qdata_res[:, a.rank:] = qdata_b[grid[:, 1]]
    # use numpys broadcasting to obtain the tensor product
    idx_reshape = (Ellipsis, ) + tuple([np.newaxis] * b.rank)
    data_a = [ta[idx_reshape] for ta in a._data]
    idx_reshape = tuple([np.newaxis] * a.rank) + (Ellipsis, )
    data_b = [tb[idx_reshape] for tb in b._data]
    res._data = [data_a[i] * data_b[j] for i, j in grid]
    res._qdata = qdata_res
    res._qdata_sorted = a._qdata_sorted and b._qdata_sorted  # since grid is lex sorted
    # labels
    res.labels = a.labels.copy()
    for k in b.labels:
        if k in res.labels:
            del res.labels[k]  # drop collision
        else:
            res.labels[k] = b.labels[k] + a.rank
    return res


def inner(a, b, axes=None, do_conj=False):
    """Contract all legs in `a` and `b`, return scalar.

    Parameters
    ----------
    a, b : class:`Array`
        The arrays for which to calculate the product.
        Must have same rank, and compatible LegCharges.
    axes : ``(axes_a, axes_b)`` | ``None``
        ``None`` is equivalent to ``(range(rank), range(rank))``.
        Alternatively, `axes_a` and `axes_b` specifiy the legs of `a` and `b`, respectively,
        which should be contracted. Legs can be specified with leg labels or indices.
        Contract leg ``axes_a[i]`` of `a` with leg ``axes_b[i]`` of `b`.
    do_conj : bool
        If ``False`` (Default), ignore it.
        if ``True``, conjugate `a` before, i.e., return ``inner(a.conj(), b, axes)``

    Returns
    -------
    inner_product : dtype
        A scalar (of common dtype of `a` and `b`) giving the full contraction of `a` and `b`.
    """
    if a.rank != b.rank:
        raise ValueError("different rank!")
    if axes is not None:
        axes_a, axes_b = axes
        axes_a = a.get_leg_indices(to_iterable(axes_a))
        axes_b = b.get_leg_indices(to_iterable(axes_b))
        if len(axes_a) != a.rank or len(axes_b) != b.rank:
            raise ValueError("no full contraction. Use tensordot instead!")
        # we can permute axes_a and axes_b. Use that to ensure axes_b = range(b.rank)
        sort_axes_b = np.argsort(axes_b)
        axes_a = [axes_a[i] for i in sort_axes_b]
        transp = (tuple(axes_a) != tuple(range(a.rank)))
    else:
        transp = False
    if transp or do_conj:
        a = a.copy(deep=False)
    if transp:
        a.itranspose(axes_a)
    if do_conj:
        a = a.iconj()
    # check charge compatibility
    if a.chinfo != b.chinfo:
        raise ValueError("different ChargeInfo")
    for lega, legb in zip(a.legs, b.legs):
        lega.test_contractible(legb)
    return _inner_worker(a, b)


def tensordot(a, b, axes=2):
    """Similar as ``np.tensordot`` but for :class:`Array`.

    Builds the tensor product of `a` and `b` and sums over the specified axes.
    Does not require complete blocking of the charges.

    Labels are inherited from `a` and `b`.
    In case of a collision (= the same label would be inherited from `a` and `b`
    after the contraction), both labels are dropped.

    Detailed implementation notes are available in the doc-string of :func:`_tensordot_worker`.

    Parameters
    ----------
    a, b : :class:`Array`
        The first and second npc Array for which axes are to be contracted.
    axes : ``(axes_a, axes_b)`` | int
        A single integer is equivalent to ``(range(-axes, 0), range(axes))``.
        Alternatively, `axes_a` and `axes_b` specifiy the legs of `a` and `b`, respectively,
        which should be contracted. Legs can be specified with leg labels or indices.
        Contract leg ``axes_a[i]`` of `a` with leg ``axes_b[i]`` of `b`.

    Returns
    -------
    a_dot_b : :class:`Array`
        The tensorproduct of `a` and `b`, summed over the specified axes.
        Returns a scalar in case of a full contraction.
    """
    if a.chinfo != b.chinfo:
        raise ValueError("Different ChargeInfo")
    try:
        axes_a, axes_b = axes
        axes_int = False
    except TypeError:
        axes = int(axes)
        axes_int = True
    if not axes_int:
        a = a.copy(deep=False)  # shallow copy allows to call itranspose
        b = b.copy(deep=False)  # which would otherwise break views.
        # step 1.) of the implementation notes: bring into standard form by transposing
        axes_a = a.get_leg_indices(to_iterable(axes_a))
        axes_b = b.get_leg_indices(to_iterable(axes_b))
        if len(axes_a) != len(axes_b):
            raise ValueError("different lens of axes for a, b: " + repr(axes))
        not_axes_a = [i for i in range(a.rank) if i not in axes_a]
        not_axes_b = [i for i in range(b.rank) if i not in axes_b]
        a.itranspose(not_axes_a + axes_a)
        b.itranspose(axes_b + not_axes_b)
        axes = len(axes_a)
    # now `axes` is integer
    # check for special cases
    if axes == 0:
        return outer(a, b)  # no sum necessary
    if axes == a.rank and axes == b.rank:
        return inner(a, b)  # full contraction

    # check for contraction compatibility
    for lega, legb in zip(a.legs[-axes:], b.legs[:axes]):
        lega.test_contractible(legb)

    # the main work is out-sourced
    res = _tensordot_worker(a, b, axes)

    # labels
    res.iset_leg_labels(list(a.get_leg_labels()[:-axes]) + [None] * (b.rank - axes))
    for k in b.labels:
        if b.labels[k] >= axes:  # not contracted
            if k in res.labels:
                del res.labels[k]  # drop collision
            else:
                res.labels[k] = b.labels[k] + a.rank - 2 * axes
    return res


def svd(a,
        full_matrices=False,
        compute_uv=True,
        cutoff=None,
        qtotal_LR=[None, None],
        inner_labels=[None, None],
        inner_qconj=+1):
    """Singualar value decomposition of an Array `a`.

    Factorizes ``U, S, VH = svd(a)``, such that ``a = U*diag(S)*VH`` (where ``*`` stands for
    a :func:`tensordot` and `diag` creates an correctly shaped Array with `S` on the diagonal).
    For a non-zero `cutoff` this holds only approximately.

    There is a gauge freedom regarding the charges, see also :meth:`Array.gauge_total_charge`.
    We ensure contractibility by setting ``U.legs[1] = VH.legs[0].conj()``.
    Further, we gauge the LegCharge such that `U` and `V` have the desired `qtotal_LR`.

    Parameters
    ----------
    a : :class:`Array`, shape ``(M, N)``
        The matrix to be decomposed.
    full_matrices : bool
        If ``False`` (default), `U` and `V` have shapes ``(M, K)`` and ``(K, N)``,
        where ``K=len(S)``.
        If ``True``, `U` and `V` are full square unitary matrices with shapes ``(M, M)`` and
        ``(N, N)``. Note that the arrays are not directly contractible in that case; ``diag(S)``
        would need to be a rectangluar ``(M, N)`` matrix.
    compute_uv : bool
        Whether to compute and return `U` and `V`.
    cutoff : ``None`` | float
        Keep only singular values which are (strictly) greater than `cutoff`.
        (Then the factorization holds only approximately).
        If ``None`` (default), ignored.
    qtotal_LR : [{charges|None}, {charges|None}]
        The desired `qtotal` for `U` and `VH`, respectively.
        ``[None, None]`` (Default) is equivalent to ``[None, a.qtotal]``.
        A single `None` entry is replaced the unique charge satisfying the requirement
        ``U.qtotal + VH.qtotal = a.qtotal (modulo qmod)``.
    inner_labels_LR: [{str|None}, {str|None}]
        The first label corresponds to ``U.legs[1]``, the second to ``VH.legs[0]``.
    inner_qconj : {+1, -1}
        Direction of the charges for the new leg. Default +1.
        The new LegCharge is constructed such that ``VH.legs[0].qconj = qconj``.

    Returns
    -------
    U : :class:`Array`
        Matrix with left singular vectors as columns.
        Shape ``(M, M)`` or ``(M, K)`` depending on `full_matrices`.
    S : 1D ndarray
        The singluar values of the array. If no `cutoff` is given, it has lenght ``min(M, N)``.
    VH : :class:`Array`
        Matrix with right singular vectors as rows.
        Shape ``(N, N)`` or ``(K, N)`` depending on `full_matrices`.
    """
    # check arguments
    if a.rank != 2:
        raise ValueError("SVD is only defined for a 2D matrix. Use LegPipes!")
    if full_matrices and ((not compute_uv) or cutoff is not None):
        raise ValueError("What do you want? Check your goals!")
    labL, labR = inner_labels
    a_labels = a.get_leg_labels()
    # ensure complete blocking
    piped_axes, a = a.as_completely_blocked()

    # figure out qtotal_LR
    qtotal_L, qtotal_R = qtotal_LR
    if qtotal_L is None and qtotal_R is None:
        qtotal_R = a.qtotal
    if qtotal_L is None:
        qtotal_L = a.chinfo.make_valid(a.qtotal - qtotal_R)
    elif qtotal_R is None:
        qtotal_R = a.chinfo.make_valid(a.qtotal - qtotal_L)
    elif np.any(a.qtotal != a.chinfo.make_valid(qtotal_L + qtotal_R)):
        raise ValueError("The entries of `qtotal_LR` have to add up to ``a.qtotal``!")
    qtotal_LR = qtotal_L, qtotal_R

    # the main work
    overwrite_a = (len(piped_axes) > 0)
    U, S, VH = _svd_worker(a, full_matrices, compute_uv, overwrite_a, cutoff, qtotal_LR,
                           inner_qconj)
    if not compute_uv:
        return S

    # 'split' pipes introduced to ensure complete blocking
    if 0 in piped_axes:
        U = U.split_legs(0)
    if 1 in piped_axes:
        VH = VH.split_legs(1)
    U.iset_leg_labels([a_labels[0], labL])
    VH.iset_leg_labels([labR, a_labels[1]])
    return U, S, VH


def pinv(a, cutoff=1.e-15):
    """Compute the (Moore-Penrose) pseudo-inverse of a matrix.

    Equivalent to the following procedure: Perform a SVD, ``U, S, VH = svd(a, cutoff=cutoff)``
    with a `cutoff` > 0, calculate ``P = U * diag(1/S) * VH``
    (with ``*`` denoting tensordot) and return ``P.conj.transpose()``.

    Parameters
    ----------
    a : (M, N) :class:`Array`
        Matrix to be pseudo-inverted.
    cuttof : float
        Cutoff for small singular values, as given to :func:`svd`.
        (Note: different convetion than numpy.)

    Returns
    -------
    B : (N, M) :class:`Array`
        The pseudo-inverse of `a`.
    """
    if cutoff <= 0.:
        raise ValueError("invalid cutoff")
    # follow exactly the procedure lined out.
    # however, use inplace methods and don't construct the diagonal matrix explicitly.
    U, S, VH = svd(a, cutoff=cutoff)
    X = VH.itranspose().iconj().iscale_axis(1. / S, axis=-1)
    Z = U.itranspose().iconj()
    return tensordot(X, Z, axes=1)


def norm(a, ord=None, convert_to_float=True):
    r"""Norm of flattened data.

    Equivalent to ``np.linalg.norm(a.to_ndarray().flatten(), ord)``.

    In contrast to numpy, we don't distinguish between matrices and vectors,
    but simply calculate the norm for the **flat** (block) data.
    The usual `ord`-norm is defined as  :math:`(\sum_i |a_i|^{ord} )^{1/ord}`.

    ==========  ======================================
    ord         norm
    ==========  ======================================
    None/'fro'  Frobenius norm (same as 2-norm)
    np.inf      ``max(abs(x))``
    -np.inf     ``min(abs(x))``
    0           ``sum(a != 0) == np.count_nonzero(x)``
    other       ususal `ord`-norm
    ==========  ======================================

    Parameters
    ----------
    a : :class:`Array` | np.ndarray
        The array of which the norm should be calculated.
    ord :
        The order of the norm. See table above.
    convert_to_float :
        Convert integer to float before calculating the norm, avoiding int overflow.

    Returns
    -------
    norm : float
        The norm over the *flat* data of the array.
    """
    if isinstance(a, Array):
        return a.norm(ord, convert_to_float)
    elif isinstance(a, np.ndarray):
        if convert_to_float:
            new_type = np.find_common_type([np.float_, a.dtype], [])  # int -> float
            a = np.asarray(a, new_type)  # doesn't copy, if the dtype did not change.
        return np.linalg.norm(a.reshape((-1, )), ord)
    else:
        raise ValueError("unknown type of a")


def eigh(a, UPLO='L', sort=None):
    r"""Calculate eigenvalues and eigenvectors for a hermitian matrix.

    ``W, V = eigh(a)`` yields :math:`a = V diag(w) V^{\dagger}`.
    **Assumes** that a is hermitian, ``a.conj().transpose() == a``.

    Parameters
    ----------
    a : :class:`Array`
        The hermitian square matrix to be diagonalized.
    UPLO : {'L', 'U'}
        Whether to take the lower ('L', default) or upper ('U') triangular part of `a`.
    sort : {'m>', 'm<', '>', '<', ``None``}
        How the eigenvalues should are sorted *within* each charge block.
        Defaults to ``None``, which is same as '<'. See :func:`argsort` for details.

    Returns
    -------
    W : 1D ndarray
        The eigenvalues, sorted within the same charge blocks according to `sort`.
    V : :class:`Array`
        Unitary matrix; ``V[:, i]`` is normalized eigenvector with eigenvalue ``W[i]``.
        The first label is inherited from `A`, the second label is ``'eig'``.

    Notes
    -----
    Requires the legs to be contractible.
    If `a` is not blocked by charge, a blocked copy is made via a permutation ``P``,
    :math:` a' =  P a P = V' W' (V')^{\dagger}`.
    The eigenvectors `V` are then obtained by the reverse permutation,
    :math:`V = P^{-1} V'` such that `A = V W V^{\dagger}`.
    """
    w, v = _eig_worker(True, a, sort, UPLO)  # hermitian
    v.iset_leg_labels([a.get_leg_labels()[0], 'eig'])
    return w, v


def eig(a, sort=None):
    r"""Calculate eigenvalues and eigenvectors for a non-hermitian matrix.

    ``W, V = eig(a)`` yields :math:`a V = V diag(w)`.

    Parameters
    ----------
    a : :class:`Array`
        The hermitian square matrix to be diagonalized.
    sort : {'m>', 'm<', '>', '<', ``None``}
        How the eigenvalues should are sorted *within* each charge block.
        Defaults to ``None``, which is same as '<'. See :func:`argsort` for details.

    Returns
    -------
    W : 1D ndarray
        The eigenvalues, sorted within the same charge blocks according to `sort`.
    V : :class:`Array`
        Unitary matrix; ``V[:, i]`` is normalized eigenvector with eigenvalue ``W[i]``.
        The first label is inherited from `A`, the second label is ``'eig'``.

    Notes
    -----
    Requires the legs to be contractible.
    If `a` is not blocked by charge, a blocked copy is made via a permutation ``P``,
    :math:` a' =  P a P = V' W' (V')^{\dagger}`.
    The eigenvectors `V` are then obtained by the reverse permutation,
    :math:`V = P^{-1} V'` such that `A = V W V^{\dagger}`.
    """
    w, v = _eig_worker(False, a, sort)  # non-hermitian
    v.iset_leg_labels([a.get_leg_labels()[0], 'eig'])
    return w, v


def eigvalsh(a, UPLO='L', sort=None):
    r"""Calculate eigenvalues for a hermitian matrix.

    **Assumes** that a is hermitian, ``a.conj().transpose() == a``.

    Parameters
    ----------
    a : :class:`Array`
        The hermitian square matrix to be diagonalized.
    UPLO : {'L', 'U'}
        Whether to take the lower ('L', default) or upper ('U') triangular part of `a`.
    sort : {'m>', 'm<', '>', '<', ``None``}
        How the eigenvalues should are sorted *within* each charge block.
        Defaults to ``None``, which is same as '<'. See :func:`argsort` for details.

    Returns
    -------
    W : 1D ndarray
        The eigenvalues, sorted within the same charge blocks according to `sort`.

    Notes
    -----
    The eigenvalues are sorted within blocks of the completely blocked legs.
    """
    return _eigvals_worker(True, a, sort, UPLO)


def eigvals(a, sort=None):
    r"""Calculate eigenvalues for a hermitian matrix.

    Parameters
    ----------
    a : :class:`Array`
        The hermitian square matrix to be diagonalized.
    sort : {'m>', 'm<', '>', '<', ``None``}
        How the eigenvalues should are sorted *within* each charge block.
        Defaults to ``None``, which is same as '<'. See :func:`argsort` for details.

    Returns
    -------
    W : 1D ndarray
        The eigenvalues, sorted within the same charge blocks according to `sort`.

    Notes
    -----
    The eigenvalues are sorted within blocks of the completely blocked legs.
    """
    return _eigvals_worker(False, a, sort)


def speigs(a, charge_sector, k, *args, **kwargs):
    """Sparse eigenvalue decomposition ``w, v`` of square `a` in a given charge sector.

    Finds `k` right eigenvectors (chosen by ``kwargs['which']``) in a given charge sector,
    ``tensordot(A, V[i], axes=1) = W[i] * V[i]``.

    Parameters
    ----------
    a : :class:`Array`
        A square array with contractible legs and vanishing total charge.
    charge_sector : charges
        `ndim` charges to select the block.
    k : int
        How many eigenvalues/vectors should be calculated.
        If the block of `charge_sector` is smaller than `k`, `k` may be reduced accordingly.
    *args, **kwargs :
        Additional arguments given to `scipy.sparse.linalg.eigs`.

    Returns
    -------
    W : ndarray
        `k` (or less) eigenvalues
    V : list of :class:`Array`
        `k` (or less) right eigenvectors of `A` with total charge `charge_sector`.
        Note that when interpreted as a matrix,
        this is the transpose of what ``np.eigs`` normally gives.
    """
    charge_sector = a.chinfo.make_valid(charge_sector).reshape((a.chinfo.qnumber, ))
    if a.rank != 2 or a.shape[0] != a.shape[1]:
        raise ValueError("expect a square matrix!")
    a.legs[0].test_contractible(a.legs[1])
    if np.any(a.qtotal != a.chinfo.make_valid()):
        raise ValueError("Non-trivial qtotal -> Nilpotent. Not diagonizable!?")
    ret_eigv = kwargs.get('return_eigenvectors', args[7] if len(args) > 7 else True)
    piped_axes, a = a.as_completely_blocked()  # ensure complete blocking

    # find the block correspoding to `charge_sector` in `a`
    block_exists = False
    for qinds, block in zip(a._qdata, a._data):
        qi = qinds[0]
        if np.any(a.chinfo.make_valid(a.legs[0].get_charge(qi)) != charge_sector):
            continue
        block_exists = True  # found the correct `block`
        res = _sp_speigs(block, k, *args, **kwargs)
        if ret_eigv:
            W, V_flat = res
        else:
            W = res
        break

    if not block_exists:  # block corresponding to charge_sector is zero
        for qi in range(a.legs[0].block_number):
            if np.all(a.chinfo.make_valid(a.legs[0].get_charge(qi)) == charge_sector):
                sl = a.legs[0].slices
                block_size = sl[qi + 1] - sl[qi]
                break
        else:
            raise ValueError("desired charge sector not present in the leg of `a`")
        k = min(block_size, k)
        W = np.zeros(k, a.dtype)
        V_flat = np.zeros((block_size, k), a.dtype)
        V_flat[:k, :k] = np.eye(k, a.dtype)  # chose standard basis as eigenvectors
    # convert V_flat to npc Arrays and return
    cdef Array U
    if ret_eigv:
        V = []
        for j in range(V_flat.shape[1]):
            U = zeros([a.legs[0]], dtype=a.dtype, qtotal=charge_sector)
            U._data = [V_flat[:, j]]
            U._qdata = np.array([[qi]], dtype=np.intp)
            if len(piped_axes) > 0:
                U = U.split_legs(0)
            V.append(U)
        return W, V
    else:
        return W


def expm(a):
    """Use scipy.linalg.expm to calculate the matrix exponential of a square matrix.

    Parameters
    ----------
    a : :class:`Array`
        A square matrix to be exponentiated.

    Returns
    -------
    exp_a : :class:`Array`
        The matrix exponential ``expm(a)``, calculated using scipy.linalg.expm.
        Same legs/labels as `a`.
    """
    if a.rank != 2 or a.shape[0] != a.shape[1]:
        raise ValueError("expect a square matrix!")
    a.legs[0].test_contractible(a.legs[1])
    if np.any(a.qtotal != a.chinfo.make_valid()):
        raise NotImplementedError("A*A has different qtotal than A; nilpotent matrix")
    piped_axes, a = a.as_completely_blocked()  # ensure complete blocking

    res = diag(1., a.legs[0], dtype=a.dtype)
    res.labels = a.labels.copy()
    for qindices, block in zip(a._qdata, a._data):  # non-zero blocks on the diagonal
        exp_block = scipy.linalg.expm(block)  # main work
        qi = qindices[0]  # `res` has all diagonal blocks,
        # so res._qdata = [[0, 0], [1, 1], [2, 2]...]
        res._data[qi] = exp_block  # replace idendity block
    if len(piped_axes) > 0:
        res = res.split_legs(piped_axes)  # revert the permutation in the axes
    return res


def qr(a, mode='reduced', inner_labels=[None, None]):
    r"""Q-R decomposition of a matrix.

    Decomposition such that ``A == npc.tensordot(q, r, axes=1)`` up to numerical rounding errors.

    Parameters
    ----------
    a : :class:`Array`
        A square matrix to be exponentiated, shape ``(M,N)``.
    mode : 'reduced', 'complete'
        'reduced': return `q` and `r` with shapes (M,K) and (K,N), where K=min(M,N)
        'complete': return `q` with shape (M,M).
    inner_labels: [{str|None}, {str|None}]
        The first label is used for ``Q.legs[1]``, the second for ``R.legs[0]``.

    Returns
    -------
    q : :class:`Array`
        If `mode` is 'complete', a unitary matrix.
        For `mode` 'reduced' such thatOtherwise such that
        :math:`q^{*}_{j,i} q_{j,k} = \delta_{i,k}`
    r : :class:`Array`
        Upper triangular matrix if both legs of A are sorted by charges;
        Otherwise a simple transposition (performed when sorting by charges) brings it to
        upper triangular form.
    """
    if a.rank != 2:
        raise ValueError("expect a matrix!")
    a_labels = a.get_leg_labels()
    label_Q, label_R = inner_labels
    piped_axes, a = a.as_completely_blocked()  # ensure complete blocking & sort
    q_data = []
    r_data = []
    i0 = 0
    a_leg0 = a.legs[0]
    inner_leg_mask = np.zeros(a_leg0.ind_len, dtype=np.bool_)
    for qindices, block in zip(a._qdata, a._data):  # non-zero blocks on the diagonal
        q_block, r_block = np.linalg.qr(block, mode)
        q_data.append(q_block)
        r_data.append(r_block)
        if mode != 'complete':
            q1, q2 = qindices
            i0 = a_leg0.slices[q1]
            inner_leg_mask[i0:i0 + q_block.shape[1]] = True
    if mode != 'complete':
        # map qindices
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            map_qind, _, inner_leg = a_leg0.project(inner_leg_mask)
    else:
        inner_leg = a_leg0
    cdef Array q = Array([a_leg0, inner_leg.conj()], a.dtype)
    q._data = q_data
    q._qdata = a._qdata.copy()
    q._qdata_sorted = False
    cdef Array r = Array([inner_leg, a.legs[1]], a.dtype, a.qtotal)
    r._data = r_data
    r._qdata = a._qdata.copy()
    r._qdata_sorted = False
    if mode != 'complete':
        q._qdata[:, 1] = map_qind[q._qdata[:, 0]]
        r._qdata[:, 0] = q._qdata[:, 1]  # copy map_qind[q._qdata[:, 0]] from q
    if len(piped_axes) > 0:  # revert the permutation in the axes
        if 0 in piped_axes:
            if mode != 'complete':
                q = q.split_legs(0)
            else:
                q = q.split_legs(0, 1)
                r = r.split_legs(0)
        if 1 in piped_axes:
            r = r.split_legs(-1)
    q.iset_leg_labels([a_labels[0], label_Q])
    r.iset_leg_labels([label_R, a_labels[1]])
    return q, r


def to_iterable_arrays(array_list):
    """Similar as :func:`~tenpy.tools.misc.to_iterable`, but also enclose npc Arrays in a list."""
    if isinstance(array_list, Array):
        array_list = [array_list]
    array_list = to_iterable(array_list)
    return array_list


# internal helper functions

def _nontrivial_grid_entries(grid):
    """Return a list [(idx, entry)] of non-``None`` entries in an array_like grid."""
    grid = np.asarray(grid, dtype=np.object)
    entries = []  # fill with (multi_index, entry)
    # use np.nditer to iterate with multi-index over the grid.
    # see https://docs.scipy.org/doc/numpy/reference/arrays.nditer.html for details.
    it = np.nditer(grid, flags=['multi_index', 'refs_ok'])  # numpy iterator
    while not it.finished:
        e = it[0].item()
        if e is not None:
            entries.append((it.multi_index, e))
        it.iternext()
    if len(entries) == 0:
        raise ValueError("No non-trivial entries in grid")
    return grid.shape, entries


# cython stuff

cdef inline np.ndarray _np_empty(np.PyArray_Dims dims, int type):
    return <np.ndarray>np.PyArray_EMPTY(dims.len, dims.ptr, type, 0 )

cdef inline np.ndarray _np_zeros(np.PyArray_Dims dims, int type):
    return <np.ndarray>np.PyArray_ZEROS(dims.len, dims.ptr, type, 0 )


@cython.wraparound(False)
@cython.boundscheck(False)
cdef np.ndarray _iter_common_sorted(
        np.ndarray a, np.ndarray b):
    """Yield indices ``i, j`` for which ``a[i] == b[j]``.

    *Assumes* that ``a[i_start:i_stop]`` and ``b[j_start:j_stop]`` are strictly ascending.
    Given that, it is equivalent to (but faster than)::

        for j, i in itertools.product(range(j_start, j_stop), range(i_start, i_stop)):
            if a[i] == b[j]:
                yield i, j
    """
    cdef int l_a = a.shape[0]
    cdef int l_b = b.shape[0]
    cdef int i=0, j=0, lres=0
    cdef np.PyArray_Dims dim
    dim.len = 2
    dim.ptr = [l_a+l_b, 2]
    cdef np.ndarray[np.intp_t, ndim=2, mode='c'] res = _np_empty(dim, np.NPY_INTP)
    while i < l_a and j < l_b:
        if a[i] < b[j]:
            i += 1
        elif b[j] < a[i]:
            j += 1
        else:
            #  yield i, j
            res[lres, 0] = i
            res[lres, 1] = j
            lres += 1
            i += 1
            j += 1
    return res[:lres]


def _inner_worker(a, b):
    """Full contraction of `a` and `b` with axes in matching order."""
    dtype = np.find_common_type([a.dtype, b.dtype], [])
    res = dtype.type(0)
    if np.any(a.chinfo.make_valid(a.qtotal + b.qtotal) != 0):
        return res  # can't have blocks to be contracted
    if a.stored_blocks == 0 or b.stored_blocks == 0:
        return res  # also trivial
    # need to find common blocks in a and b, i.e. equal leg charges.
    # for faster comparison, generate 1D arrays with a combined index
    stride = np.cumprod([1] + [l.block_number for l in a.legs[:-1]])
    a_qdata = np.sum(a._qdata * stride, axis=1)
    a_data = a._data
    if not a._qdata_sorted:
        perm = np.argsort(a_qdata)
        a_qdata = a_qdata[perm]
        a_data = [a_data[i] for i in perm]
    b_qdata = np.sum(b._qdata * stride, axis=1)
    b_data = b._data
    if not b._qdata_sorted:
        perm = np.argsort(b_qdata)
        b_qdata = b_qdata[perm]
        b_data = [b_data[i] for i in perm]
    for i, j in _iter_common_sorted(a_qdata, b_qdata):
        res += np.inner(a_data[i].reshape((-1, )), b_data[j].reshape((-1, )))
    return res


cdef _tensordot_pre_sort(Array a, Array b, int cut_a, int cut_b, np.dtype calc_dtype):
    """Pre-calculations before the actual matrix product.

    Called by :func:`_tensordot_worker`.
    See doc-string of :func:`tensordot` for details on the implementation.

    Parameters
    ----------
    a, b : :class:`Array`
        the arrays to be contracted with tensordot. Should have non-empty ``a._data``
    cut_a, cut_b : int
        contract `a.legs[cut_a:]` with `b.legs[:cut_b]`
    calc_dtype: np.ndtype
        The data type used for the calculation.

    Returns
    -------
    a_data, a_qdata_keep, a_qdata_contr, b_data, b_qdata_keep, b_qdata_contr
    """
    cdef list a_data, b_data
    cdef np.ndarray[np.intp_t, ndim=2] a_qdata_keep, b_qdata_keep
    cdef np.ndarray[np.intp_t, ndim=1] a_qdata_contr, b_qdata_contr
    # convert qindices over which we sum to a 1D array for faster lookup/iteration
    stride = np.cumprod([1] + [l.block_number for l in a.legs[cut_a:-1]])
    a_qdata_contr = np.sum(a._qdata[:, cut_a:] * stride, axis=1)
    # lex-sort a_qdata, dominated by the axes kept, then the axes summed over.
    a_sort = np.lexsort(np.append(a_qdata_contr[:, np.newaxis], a._qdata[:, :cut_a], axis=1).T)
    a_qdata_keep = a._qdata[a_sort, :cut_a]
    a_qdata_contr = a_qdata_contr[a_sort]
    a_data = a._data
    a_data = [a_data[i] for i in a_sort]
    # combine all b_qdata[axes_b] into one column (with the same stride as before)
    b_qdata_contr = np.sum(b._qdata[:, :cut_b] * stride, axis=1)
    # lex-sort b_qdata, dominated by the axes summed over, then the axes kept.
    b_data = b._data
    if not b._qdata_sorted:
        b_sort = np.lexsort(np.append(b_qdata_contr[:, np.newaxis], b._qdata[:, cut_b:], axis=1).T)
        b_qdata_keep = b._qdata[b_sort, cut_b:]
        b_qdata_contr = b_qdata_contr[b_sort]
        b_data = [b_data[i] for i in b_sort]
    else:
        b_data = list(b_data)  # make a copy: we write into it
        b_qdata_keep = b._qdata[:, cut_b:]
    return a_data, a_qdata_keep, a_qdata_contr, b_data, b_qdata_keep, b_qdata_contr


cdef _tensordot_match_charges(int n_rows_a,
                              int n_cols_b,
                              int qnumber,
                              np.ndarray a_charges_keep,
                              np.ndarray b_charges_match):
    """Estimate number of blocks in res and get order for iteration over row_a and col_b

    Parameters
    ----------
    a_charges_keep, b_charges_match: 2D ndarray
        (Unsorted) charges of dimensions (n_rows_a, qnumber) and (n_cols_b, qnumber)

    Returns
    -------
    max_n_blocks_res : int
        Maximum number of block in the result a.dot(b)
    row_a_sort: np.ndarray[np.intp_t, ndim=1]
    match_rows: np.ndarray[np.intp_t, ndim=2]
        For given `col_b`, rows given by `row_a` in
        ``row_a_sort[match_rows[col_b, 0]:match_rows[col_b,1]]`` fulfill
        ``a_charges_keep[col_a, :] == b_charges_match[col_b, :]``
    """
    # This is effectively a more complicated version of _iter_common_sorted....
    cdef np.ndarray[np.intp_t, ndim=2] match_rows = np.empty((n_cols_b, 2), np.intp)
    if qnumber == 0:  # special case no restrictions due to charge
        match_rows[:, 0] = 0
        match_rows[:, 1] = n_rows_a
        return n_rows_a * n_cols_b, np.arange(n_rows_a), match_rows
    # general case
    cdef np.ndarray[np.intp_t, ndim=1] row_a_sort = np.lexsort(a_charges_keep.T)
    cdef np.ndarray[np.intp_t, ndim=1] col_b_sort = np.lexsort(b_charges_match.T)
    cdef int res_max_n_blocks = 0
    cdef int i=0, j=0, i0, j0, ax, j1
    cdef int i_s, j_s, i0_s, j0_s  # corresponding entries in row_a_sort/col_b_sort
    cdef int lexcomp
    while i < n_rows_a and j < n_cols_b: # go through sort_a and sort_b at the same time
        i_s = row_a_sort[i]
        j_s = col_b_sort[j]
        # lexcompare a_charges_keep[i_s, :] and b_charges_match[j_s, :]
        lexcomp = 0
        for ax in range(qnumber-1, -1, -1):
            if a_charges_keep[i_s, ax] > b_charges_match[j_s, ax]:
                lexcomp = 1
                break
            elif a_charges_keep[i_s, ax] < b_charges_match[j_s, ax]:
                lexcomp = -1
                break
        if lexcomp > 0:  # a_charges_keep is larger: advance j
            match_rows[j_s, 0] = 0  # nothing to iterate for this col_b = j_s
            match_rows[j_s, 1] = 0
            j += 1
            continue
        elif lexcomp < 0: # b_charges_match is larger
            i += 1
            continue
        # else: charges for i_s and j_s and match
        # which/how many rows_a have the same charge? Increase i until the charges change.
        i0 = i
        i0_s = i_s
        i += 1
        while i < n_rows_a:
            i_s = row_a_sort[i]
            lexcomp = 0
            for ax in range(qnumber-1, -1, -1):
                if a_charges_keep[i_s, ax] != a_charges_keep[i0_s, ax]:
                    lexcomp = 1
                    break
            if lexcomp > 0:  # (sorted -> can only increase)
                break
            i += 1
        # => the rows in row_a_sort[i0:i] have the current charge
        j0 = j
        j0_s = j_s
        j += 1
        while j < n_cols_b:
            j_s = col_b_sort[j]
            lexcomp = 0
            for ax in range(qnumber-1, -1, -1):
                if b_charges_match[j_s, ax] != b_charges_match[j0_s, ax]:
                    lexcomp = 1
                    break
            if lexcomp > 0:  # (sorted -> can only increase)
                break
            j += 1
        # => the colums in col_b_sort[j0:j] have the current charge
        # save rows for iteration for the given j_s in col_b
        for j1 in range(j0, j):
            j_s = col_b_sort[j1]
            match_rows[j_s, 0] = i0
            match_rows[j_s, 1] = i
        res_max_n_blocks += (j-j0) * (i-i0)
    for j1 in range(j, n_cols_b):
        j_s = col_b_sort[j1]
        match_rows[j_s, 0] = 0
        match_rows[j_s, 1] = 0
    return res_max_n_blocks, row_a_sort, match_rows


cdef _tensordot_worker(Array a, Array b, int axes):
    """Main work of tensordot, called by :func:`tensordot`.

    Assumes standard form of parameters: axes is integer,
    sum over the last `axes` legs of `a` and first `axes` legs of `b`.

    Notes
    -----
    Looking at the source of numpy's tensordot (which is just 62 lines of python code),
    you will find that it has the following strategy:

    1. Transpose `a` and `b` such that the axes to sum over are in the end of `a` and front of `b`.
    2. Combine the legs `axes`-legs and other legs with a `np.reshape`,
       such that `a` and `b` are matrices.
    3. Perform a matrix product with `np.dot`.
    4. Split the remaining axes with another `np.reshape` to obtain the correct shape.

    The main work is done by `np.dot`, which calls LAPACK to perform the simple matrix product.
    [This matrix multiplication of a ``NxK`` times ``KxM`` matrix is actually faster
    than the O(N*K*M) needed by a naive implementation looping over the indices.]

    We follow the same overall strategy, viewing the :class:`Array` as a tensor with
    data block entries.
    Step 1) is performed directly in :func:`tensordot`.

    The steps 2) and 4) could be implemented with :meth:`Array.combine_legs`
    and :meth:`Array.split_legs`.
    However, that would actually be an overkill: we're not interested
    in the full charge data of the combined legs (which would be generated in the LegPipes).
    Instead, we just need to track the qindices of the `a._qdata` and `b._qdata` carefully.

    Our step 2) is implemented in :func:`_tensordot_pre_worker`:
    We split `a._qdata` in `a_qdata_keep` and `a_qdata_sum`, and similar for `b`.
    Then, view `a` is a matrix :math:`A_{i,k1}` and `b` as :math:`B_{k2,j}`, where
    `i` can be any row of `a_qdata_keep`, `j` can be any row of `b_qdata_keep`.
    The `k1` and `k2` are rows of `a_qdata_sum` and `b_qdata_sum`, which stem from the same legs
    (up to a :meth:`LegCharge.conj()`).
    In our storage scheme, `a._data[s]` then contains the block :math:`A_{i,k1}` for
    ``j = a_qdata_keep[s]`` and ``k1 = a_qdata_sum[s]``.
    To identify the different indices `i` and `j`, it is easiest to lexsort in the `s`.
    Note that we give priority to the `#_qdata_keep` over the `#_qdata_sum`, such that
    equal rows of `i` are contiguous in `#_qdata_keep`.
    Then, they are identified with :func:`Charges._find_row_differences`.

    Now, the goal is to calculate the sums :math:`C_{i,j} = sum_k A_{i,k} B_{k,j}`,
    analogous to step 3) above. This is implemented in :func:`_tensordot_worker`.
    It is done 'naively' by explicit loops over ``i``, ``j`` and ``k``.
    However, this is not as bad as it sounds:
    First, we loop only over existent ``i`` and ``j``
    (in the sense that there is at least some non-zero block with these ``i`` and ``j``).
    Second, if the ``i`` and ``j`` are not compatible with the new total charge,
    we know that ``C_{i,j}`` will be zero.
    Third, given ``i`` and ``j``, the sum over ``k`` runs only over
    ``k1`` with nonzero :math:`A_{i,k1}`, and ``k2` with nonzero :math:`B_{k2,j}`.

    How many multiplications :math:`A_{i,k} B_{k,j}` we actually have to perform
    depends on the sparseness. In the ideal case, if ``k`` (i.e. a LegPipe of the legs summed over)
    is completely blocked by charge, the 'sum' over ``k`` will contain at most one term!
    """
    chinfo = a.chinfo
    if a.stored_blocks == 0 or b.stored_blocks == 0:  # special case: `a` or `b` is 0
        return zeros(a.legs[:-axes] + b.legs[axes:],
                     np.find_common_type([a.dtype, b.dtype], []), a.qtotal + b.qtotal)
    cdef int cut_a = a.rank - axes
    cdef int cut_b = axes
    cdef int b_rank = b.rank
    cdef int res_rank = cut_a + b_rank - cut_b
    # determine calculation type and result type
    dtype = np.find_common_type([a.dtype, b.dtype], [])
    prefix, res_dtype, _ = BLAS.find_best_blas_type(dtype=dtype)
    # we use 64-bit float calculations....
    calc_dtype = np.dtype({'s': np.float64,
                           'd': np.float64,
                           'c': np.complex128,
                           'z': np.complex128}[prefix])
    cdef int CALC_DTYPE_NUM = calc_dtype.num  # can be compared to np.NPY_DOUBLE/NPY_CDOUBLE
    cdef bint USE_NPY_DOT = (CALC_DTYPE_NUM != np.NPY_DOUBLE and
                             CALC_DTYPE_NUM != np.NPY_CDOUBLE)

    cdef list a_data, b_data
    cdef np.ndarray[np.intp_t, ndim=2] a_qdata_keep, b_qdata_keep
    cdef np.ndarray[np.intp_t, ndim=1] a_qdata_contr, b_qdata_contr, a_qdata_contr_sl, b_qdata_contr_sl
    # pre_worker
    a_data, a_qdata_keep, a_qdata_contr, b_data, b_qdata_keep, b_qdata_contr = _tensordot_pre_sort(a, b, cut_a, cut_b, calc_dtype)

    cdef int len_a_data = len(a_data)
    cdef int len_b_data = len(b_data)

    # find blocks where a_qdata_keep and b_qdata_keep change; use that they are sorted.
    cdef np.ndarray[np.intp_t, ndim=1] a_slices = _c_find_row_differences(a_qdata_keep)
    cdef np.ndarray[np.intp_t, ndim=1] b_slices = _c_find_row_differences(b_qdata_keep)
    # the slices divide a_data and b_data into rows and columns
    cdef int n_rows_a = a_slices.shape[0] - 1
    cdef int n_cols_b = b_slices.shape[0] - 1
    a_qdata_keep = a_qdata_keep[a_slices[:n_rows_a]]
    b_qdata_keep = b_qdata_keep[b_slices[:n_cols_b]]

    cdef np.ndarray block
    cdef int row_a, col_b, k_contr, i, j, ax  # indices
    cdef int m, n, k   # reshaped dimensions: a_block.shape = (m, k), b_block.shape = (k,n)
    cdef np.ndarray[np.intp_t, ndim=2] a_shape_keep = np.empty((n_rows_a, cut_a), np.intp)
    cdef np.ndarray[np.intp_t, ndim=1] block_dim_a_keep = np.empty(n_rows_a, np.intp)
    cdef np.ndarray[np.intp_t, ndim=1] block_dim_a_contr = np.empty(len_a_data, np.intp)
    # inline what's  _tensordot_pre_reshape in the python version
    cdef np.PyArray_Dims shp2  # shape for 2D array
    shp2.len = 2
    shp2.ptr = [0, 0]
    for row_a in range(n_rows_a):
        i = a_slices[row_a]
        block = <np.ndarray> a_data[i]
        n = 1
        for ax in range(cut_a):
            a_shape_keep[row_a, ax] = block.shape[ax]
            n *= block.shape[ax]
        block_dim_a_keep[row_a] = n
        shp2.ptr[0] = n
        for j in range(a_slices[row_a], a_slices[row_a+1]):
            block = np.PyArray_GETCONTIGUOUS((<np.ndarray> a_data[j]).astype(calc_dtype))
            m = block.size / n
            block_dim_a_contr[j] = m  # needed for dgemm
            if USE_NPY_DOT:
                # we actually have to reshape a_data
                shp2.ptr[1] = m
                a_data[j] = np.PyArray_Newshape(block, &shp2, np.NPY_CORDER)
            else:  # we need just pointers; no need to reshape
                a_data[j] = block
    cdef np.ndarray[np.intp_t, ndim=2] b_shape_keep = np.empty((n_cols_b, b_rank-cut_b), np.intp)
    cdef np.ndarray[np.intp_t, ndim=1] block_dim_b_keep = np.empty(n_cols_b, np.intp)
    for col_b in range(n_cols_b):
        i = b_slices[col_b]
        block = <np.ndarray> b_data[i]
        n = 1
        for ax in range(b_rank-cut_b):
            b_shape_keep[col_b, ax] = block.shape[ax+cut_b]
            n *= block.shape[ax+cut_b]
        block_dim_b_keep[col_b] = n
        shp2.ptr[1] = n
        for j in range(b_slices[col_b], b_slices[col_b+1]):
            block = np.PyArray_GETCONTIGUOUS((<np.ndarray> b_data[j]).astype(calc_dtype))
            m = block.size / n
            if USE_NPY_DOT:
                # we actually have to reshape a_data
                shp2.ptr[0] = m
                b_data[j] = np.PyArray_Newshape(block, &shp2, np.NPY_CORDER)
            else:  # we need just pointers; no need to reshape...
                b_data[j] = block

    # Step 3) loop over column/row of the result
    # (rows_a changes faster than cols_b, such that the resulting array is qdata lex-sorted)

    # first find output colum/row indices of the result, which are compatible with the charges
    cdef np.ndarray[QTYPE_t, ndim=2] a_charges_keep = _partial_qtotal(
        a.chinfo, a.legs[:cut_a], a_qdata_keep)
    cdef np.ndarray[QTYPE_t, ndim=2] b_charges_keep = _partial_qtotal(
        a.chinfo, b.legs[cut_b:], b_qdata_keep)
    cdef np.ndarray[QTYPE_t, ndim=1] qtotal = chinfo._make_valid_1D(a.qtotal + b.qtotal)
    # a_charges_match: for each row in a, which charge in b is compatible?
    cdef np.ndarray[QTYPE_t, ndim=2] b_charges_match = chinfo._make_valid_2D(qtotal - b_charges_keep)
    cdef np.ndarray[np.intp_t, ndim=1] row_a_sort
    cdef np.ndarray[np.intp_t, ndim=2] match_rows
    cdef int res_max_n_blocks, res_n_blocks = 0
    # the main work for that is in _tensordot_match_charges
    res_max_n_blocks, row_a_sort, match_rows = _tensordot_match_charges(
        n_rows_a, n_cols_b, a.chinfo.qnumber, a_charges_keep, b_charges_match)

    cdef list res_data = []
    cdef np.ndarray[np.intp_t, ndim=2] res_qdata = np.empty((res_max_n_blocks, res_rank), np.intp)
    cdef np.ndarray[np.intp_t, ndim=2, mode='c'] inds_contr  # takes the inner indices
    cdef int match0, match1

    #  cdef vector[int] M, N, K, G
    #  cdef vector[void*] A, B, C
    cdef np.ndarray a_block, b_block, c_block
    cdef np.PyArray_Dims c_block_shape
    c_block_shape.len = res_rank
    c_block_shape.ptr = <np.npy_intp*>PyMem_Malloc(res_rank * sizeof(np.npy_intp))
    if not c_block_shape.ptr:
        raise MemoryError

    # #### the actual loop executing the summation over blocks
    for col_b in range(n_cols_b):  # columns of b
        match0 = match_rows[col_b, 0]
        match1 = match_rows[col_b, 1]
        if match1 == match0:
            continue
        b_qdata_contr_sl = b_qdata_contr[b_slices[col_b]:b_slices[col_b+1]]
        for ax in range(b_rank - cut_b):
            c_block_shape.ptr[cut_a + ax] = b_shape_keep[col_b, ax]
        n = block_dim_b_keep[col_b]
        for row_a in row_a_sort[match0:match1]:  # rows of a
            a_qdata_contr_sl = a_qdata_contr[a_slices[row_a]:a_slices[row_a+1]]
            # find common inner indices
            inds_contr = _iter_common_sorted(a_qdata_contr_sl, b_qdata_contr_sl)
            if inds_contr.shape[0] == 0:
                continue  # no compatible blocks for given row_a, col_b

            # sum over inner indices
            for ax in range(cut_a):
                c_block_shape.ptr[ax] = a_shape_keep[row_a, ax]
            m = block_dim_a_keep[row_a]

            i = a_slices[row_a] + inds_contr[0, 0]
            j = b_slices[col_b] + inds_contr[0, 1]
            k = block_dim_a_contr[i]
            a_block = <np.ndarray> a_data[i]
            b_block = <np.ndarray> b_data[j]
            if USE_NPY_DOT:
                c_block = np.dot(a_block, b_block)
            else:
                c_block = _np_empty(c_block_shape, CALC_DTYPE_NUM)
                if CALC_DTYPE_NUM == np.NPY_DOUBLE:
                    _blas_dgemm(m, n, k, np.PyArray_DATA(a_block), np.PyArray_DATA(b_block),
                                0., np.PyArray_DATA(c_block))
                else: # if CALC_DTYPE_NUM == np.NPY_CDOUBLE:
                    _blas_zgemm(m, n, k, np.PyArray_DATA(a_block), np.PyArray_DATA(b_block),
                                0., np.PyArray_DATA(c_block))
            for k_contr in range(1, inds_contr.shape[0]):
                i = a_slices[row_a] + inds_contr[k_contr, 0]
                j = b_slices[col_b] + inds_contr[k_contr, 1]
                k = block_dim_a_contr[i]
                a_block = <np.ndarray> a_data[i]
                b_block = <np.ndarray> b_data[j]
                if USE_NPY_DOT:
                    c_block += np.dot(a_block, b_block)
                elif CALC_DTYPE_NUM == np.NPY_DOUBLE:
                    _blas_dgemm(m, n, k, np.PyArray_DATA(a_block), np.PyArray_DATA(b_block),
                                1., np.PyArray_DATA(c_block))
                else: # if CALC_DTYPE_NUM == np.NPY_CDOUBLE:
                    _blas_zgemm(m, n, k, np.PyArray_DATA(a_block), np.PyArray_DATA(b_block),
                                1., np.PyArray_DATA(c_block))
            # Step 4) reshape back to tensors
            if USE_NPY_DOT:
                c_block = np.PyArray_Newshape(c_block, &c_block_shape, np.NPY_CORDER)
            # else: c_block already created in the correct shape, which is ignored by BLAS.
            if res_dtype.num != CALC_DTYPE_NUM:
                c_block = c_block.astype(res_dtype)
            for ax in range(cut_a):
                res_qdata[res_n_blocks, ax] = a_qdata_keep[row_a, ax]
            for ax in range(b_rank - cut_b):
                res_qdata[res_n_blocks, cut_a + ax] = b_qdata_keep[col_b, ax]
            res_data.append(c_block)
            res_n_blocks += 1

    PyMem_Free(c_block_shape.ptr)
    cdef Array res = Array(a.legs[:cut_a] + b.legs[cut_b:], res_dtype, qtotal)
    if res_n_blocks != 0:
        # (at least one entry is non-empty, so res_qdata[keep] is also not empty)
        if res_n_blocks != res_max_n_blocks:
            res_qdata = res_qdata[:res_n_blocks, :]
        res._qdata = res_qdata
        res._qdata_sorted = True
        res._data = res_data
    return res


@cython.wraparound(False)
@cython.boundscheck(False)
cdef void _blas_dgemm(int M, int N, int K, void* A, void* B, double beta, void* C) nogil:
    """use blas to calculate ``C = A.dot(B) + beta * C``, overwriting to C.

    Assumes (!) that A, B, C are contiguous C-style matrices of dimensions MxK, KxN , MxN.
    """
    # HACK: We want ``C = A.dot(B)``, but this is equivalent to ``C.T = B.T.dot(A.T)``.
    # reading a C-style matrix A of dimensions MxK as F-style Matrix with LD= K yields A.T
    # Thus we can use C-style A, B, C without transposing.
    cdef char * tr = 'n'
    cdef double alpha = 1.
    # fortran call of dgemm(transa, transb, M, N, K, alpha, A, LDB, B, LDB, beta, C LDC)
    # but switch A <-> B and M <-> N to transpose everything
    dgemm(tr, tr, &N, &M, &K, &alpha, <double*> B, &N, <double*> A, &K, &beta, <double*> C, &N)

@cython.wraparound(False)
@cython.boundscheck(False)
cdef void _blas_zgemm(int M, int N, int K, void* A, void* B, double complex beta, void* C) nogil:
    """use blas to calculate C = A.B + beta C, overwriting to C

    Assumes (!) that A, B, C are contiguous F-style matrices of dimensions MxK, KxN , MxN."""
    cdef char * tr = 'n'
    cdef double complex alpha = 1.
    # switch A <-> B and M <-> N to transpose everything: c.f. _blas_dgemm
    zgemm(tr, tr, &N, &M, &K, &alpha, <double complex*> B, &N, <double complex*> A, &K, &beta,
          <double complex*> C, &N)


def _svd_worker(a, full_matrices, compute_uv, overwrite_a, cutoff, qtotal_LR, inner_qconj):
    """Main work of svd. Assumes that `a` is 2D and completely blocked."""
    chinfo = a.chinfo
    qtotal_L, qtotal_R = qtotal_LR
    at = 0  # will be gradually increased, counting the number of singular values
    S = []
    if compute_uv:
        U_data = []
        U_qdata = []
        VH_data = []
        VH_qdata = []
    new_leg_slices = []
    new_leg_charges = []
    if full_matrices:
        new_leg_slices_full = []
        at_full = 0

    # main loop
    for a_qdata_row, block in zip(a._qdata, a._data):
        if compute_uv:
            U_b, S_b, VH_b = svd_flat(block, full_matrices, True, overwrite_a, check_finite=True)
            if anynan(U_b) or anynan(VH_b) or anynan(S_b):
                # give it another try with the other (more stable) svd driver
                U_b, S_b, VH_b = svd_flat(block, full_matrices, True, overwrite_a,
                                          check_finite=True, lapack_driver='gesvd')
            if anynan(U_b) or anynan(VH_b) or anynan(S_b):
                raise ValueError(
                    "NaN in U_b {0:d} and/or VH_b: {1:d}".format(np.sum(np.isnan(U_b)),
                                                                 np.sum(np.isnan(VH_b))))
        else:
            S_b = svd_flat(block, False, False, overwrite_a, check_finite=True)
        if anynan(S_b):
            raise ValueError("NaN in S: " + str(np.sum(np.isnan(S_b))))

        if cutoff is not None:
            keep = (S_b > cutoff)  # bool array
            S_b = S_b[keep]
            if compute_uv:
                U_b = U_b[:, keep]
                VH_b = VH_b[keep, :]
        num = len(S_b)
        if num > 0:  # have new singular values
            S.append(S_b)
            if compute_uv:
                qi_L, qi_R = a_qdata_row
                qi_C = len(new_leg_slices)
                # qind_row for the new leg at the *right*, `VH.legs[0]`.
                new_leg_slices.append(at)
                charges_row = (qtotal_R - a.legs[1].get_charge(qi_R)) * inner_qconj
                new_leg_charges.append(charges_row)
                U_data.append(U_b.astype(a.dtype, copy=False))
                VH_data.append(VH_b.astype(a.dtype, copy=False))
                U_qdata.append(np.array([qi_L, qi_C], dtype=np.intp))
                VH_qdata.append(np.array([qi_C, qi_R], dtype=np.intp))
        if full_matrices:
            # num will be min(block.shape) > 0 and compute_uv=True
            # Thus we inserted U_b and V_H already to U_data and VH_data!
            # just need to take care of the second LegCharge required...
            new_leg_slices_full.append(at_full)
            at_full += max(block.shape)
        at += num
    if at == 0:
        raise RuntimeError("SVD found no singluar values")  # (at least none > cutoff)
    S = np.concatenate(S)
    if not compute_uv:
        return (None, S, None)
    # else: compute_uv is True
    new_leg_slices = np.append(new_leg_slices, [at])
    new_leg_charges = chinfo.make_valid(new_leg_charges)
    new_leg_R = LegCharge.from_qind(chinfo, new_leg_slices, new_leg_charges, inner_qconj)
    new_leg_L = new_leg_R.conj()
    if full_matrices:
        new_leg_slices_full = np.append(new_leg_slices_full, [at_full])
        new_leg_full = LegCharge.from_qind(chinfo, new_leg_slices_full, new_leg_charges,
                                           inner_qconj)
        if a.shape[0] >= a.shape[1]:  # new_leg_R is fine
            new_leg_L = new_leg_full.conj()
        else:  # new_leg_L is fine
            new_leg_R = new_leg_full
    U = Array([a.legs[0], new_leg_L], a.dtype, qtotal_L)
    VH = Array([new_leg_R, a.legs[1]], a.dtype, qtotal_R)
    U._data = U_data
    U._qdata = np.array(U_qdata, dtype=np.intp)
    U._qdata_sorted = a._qdata_sorted
    VH._data = VH_data
    VH._qdata = np.array(VH_qdata, dtype=np.intp)
    VH._qdata_sorted = a._qdata_sorted
    return U, S, VH


def _eig_worker(hermitian, a, sort, UPLO='L'):
    """Worker for ``eig``, ``eigh``"""
    if a.rank != 2 or a.shape[0] != a.shape[1]:
        raise ValueError("expect a square matrix!")
    a.legs[0].test_contractible(a.legs[1])
    if np.any(a.qtotal != a.chinfo.make_valid()):
        raise ValueError("Non-trivial qtotal -> Nilpotent. Not diagonizable!?")

    piped_axes, a = a.as_completely_blocked()  # ensure complete blocking

    dtype = np.float if hermitian else np.complex
    resw = np.zeros(a.shape[0], dtype=dtype)
    resv = diag(1., a.legs[0], dtype=np.promote_types(dtype, a.dtype))
    # w, v now default to 0 and the Identity
    for qindices, block in zip(a._qdata, a._data):  # non-zero blocks on the diagonal
        if hermitian:
            rw, rv = np.linalg.eigh(block, UPLO)
        else:
            rw, rv = np.linalg.eig(block)
        if sort is not None:  # apply sorting options
            perm = argsort(rw, sort)
            rw = np.take(rw, perm)
            rv = np.take(rv, perm, axis=1)
        qi = qindices[0]  # both `a` and `resv` are sorted and share the same qindices
        resv._data[qi] = rv  # replace idendity block
        resw[a.legs[0].get_slice(qi)] = rw  # replace eigenvalues
    if len(piped_axes) > 0:
        resv = resv.split_legs(0)  # the 'outer' facing leg is permuted back.
    return resw, resv


def _eigvals_worker(hermitian, a, sort, UPLO='L'):
    """Worker for ``eigvals``, ``eigvalsh``"""
    if a.rank != 2 or a.shape[0] != a.shape[1]:
        raise ValueError("expect a square matrix!")
    a.legs[0].test_contractible(a.legs[1])
    if np.any(a.qtotal != a.chinfo.make_valid()):
        raise ValueError("Non-trivial qtotal -> Nilpotent. Not diagonizable!?")
    piped_axes, a = a.as_completely_blocked()  # ensure complete blocking

    dtype = np.float if hermitian else np.complex
    resw = np.zeros(a.shape[0], dtype=dtype)
    # w now default to 0
    for qindices, block in zip(a._qdata, a._data):  # non-zero blocks on the diagonal
        if hermitian:
            rw = np.linalg.eigvalsh(block, UPLO)
        else:
            rw = np.linalg.eigvals(block)
        if sort is not None:  # apply sorting options
            perm = argsort(rw, sort)
            rw = np.take(rw, perm)
        qi = qindices[0]  # both `a` and `resv` are sorted and share the same qindices
        resw[a.legs[0].get_slice(qi)] = rw  # replace eigenvalues
    return resw
