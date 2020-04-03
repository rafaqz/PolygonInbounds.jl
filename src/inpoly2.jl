"""
    s = inpoly2(vert, node, [edge=Nothing, atol=0.0, rtol=eps(), outformat=InOnOut{1,0,-1}])

Check all points defined by `vert` are inside, outside or on bounds of
polygon defined by `node` and `edge`.

`vert` and `node` are matrices with the x-coordinates in the first
and the y-coordinates in the second column.

`edge` is an integer matrix of same size as `node`. The first column contains
the index of the starting node, the second column the index of the ending node.
The polygon needs to be closed. It may contain unconnected cycles.

A point is considered on boundary, if its Euclidian distance to any edge is less
than or equal `max(atol, rtol * span)`, where span is the maximum extension of the
polygon in either direction.

If a point is considered on bounds, no further check is made to determine it it is inside or 
outside numerically.

Expected effort of the algorithm is `(N+M)*log(M)`, where `M` is the number of points
and `N` is the number of polygon edges.
"""
function inpoly2(vert, node, edge=zeros(Int); atol::T=0.0, rtol::T=NaN, outformat=InOnBit) where T<:AbstractFloat

    rtol = isnan(rtol) ? eps(T)^0.85 : rtol
    poly = PolygonMesh(node, edge)
    points = PointsInbound(vert)
    nvrt = length(points)

    vmin = minimum(points)
    vmax = maximum(points)
    ddxy = vmax - vmin
    lbar = sum(ddxy) / 2
    # flip coordinates so y-span of points >= x-span of points
    flip = ddxy[1] > ddxy[2]
    ivec = sortperm(points, 2-flip)
    ac = areacount(poly)
    stat = falses(nvrt,2,ac)
    statv = view(stat, ivec, :, :)

    tol = max(abs(rtol * lbar), abs(atol))
    inpoly2!(points, ivec, poly, flip, tol, statv)
    convertout(outformat, InOnBit, stat)
end

"""
    inpoly2_mat(vert, node, edge, fTol, stats)

INPOLY2_MAT the local m-code version of the crossing-number
test. Loop over edges; do a binary-search for the first ve-
rtex that intersects with the edge y-range; do crossing-nu-
mber comparisons; break when the local y-range is exceeded.
"""
function inpoly2!(points, ivec, poly, flip::Bool, veps::AbstractFloat, stat::T) where {N,T<:AbstractArray{Bool,N}}

    nvrt = length(points)   # number of points to be checked
    nedg = edgecount(poly)  # number of edges of the polygon mesh
    
    ix = flip + 1
    iy = 2 - flip
    #----------------------------------- loop over polygon edges
    for epos = 1:nedg

        inod = egdeindex(poly, epos, 1)  # from
        jnod = egdeindex(poly, epos, 2)  # to
        # swap order of vertices
        if vertex(poly, inod, iy) > vertex(poly, jnod, iy)
            inod, jnod = jnod, inod
        end

        #------------------------------- calc. edge bounding-box
        xone = vertex(poly, inod, ix)
        yone = vertex(poly, inod, iy)
        xtwo = vertex(poly, jnod, ix)
        ytwo = vertex(poly, jnod, iy)

        xmin = min(xone, xtwo) - veps
        xmax = max(xone, xtwo) + veps
        ymin = yone - veps
        ymax = ytwo + veps

        ydel = ytwo - yone
        xdel = xtwo - xone
        feps = veps * hypot(xdel, ydel)

        # find top points[:,iy] < ymin by binary search
        ilow = 1
        iupp = nvrt
        while ilow < iupp - 1
            imid = ilow + (iupp-ilow) ÷ 2
            if vertex(points, ivec[imid], iy) < ymin
                ilow = imid
            else
                iupp = imid
            end
        end
        while ilow > 0 && vertex(points, ivec[ilow], iy) >= ymin
            ilow = ilow - 1
        end

        #------------------------------- calc. edge-intersection
        # loop over all points with y ∈ [ymin,ymax]
        for jpos = ilow+1:nvrt
            # bnds[jpos] && continue
            ypos = vertex(points, ivec[jpos], iy)
            ypos > ymax && break 
            xpos = vertex(points, ivec[jpos], ix)

            if xpos >= xmin
                if xpos <= xmax
                    #--------- inside extended bounding box of edge
                    mul1 = ydel * (xpos - xone)
                    mul2 = xdel * (ypos - yone)
                    if abs(mul2 - mul1) <= feps
                        #------- distance from line through edge less veps
                        if !(xdel * (xpos - xone) < ydel * (yone - ypos) &&
                             hypot(xpos- xone, ypos - yone) > veps ||
                             xdel * (xpos - xtwo) > ydel * (ytwo - ypos) &&
                             hypot(xpos- xtwo, ypos - ytwo) > veps)
                            # ---- round boundaries around endpoints of edge
                            setonbounds!(poly, stat, jpos, epos)
                        end
                        if mul1 < mul2 && yone <= ypos < ytwo
                            #----- left of line && ypos exact to avoid multiple counting
                            flipio!(poly, stat, jpos, epos)
                        end
                    elseif mul1 < mul2 && yone <= ypos < ytwo
                        #----- left of line && ypos exact to avoid multiple counting
                        flipio!(poly, stat, jpos, epos)
                    end
                end
            else # xpos < xmin - left of bounding box
                if yone <= ypos <  ytwo
                    #----- ypos exact to avoid multiple counting
                    flipio!(poly, stat, jpos, epos)
                end
            end
        end
    end
    stat
end

"""
    flipio!(poly, stat, p, epos)

Flip boolean value of in-out-status of point `p` for all areas associated with edge `epos`. 
"""
function flipio!(poly::PolygonMesh, stat::AbstractArray{Bool}, i::Integer, j::Integer)
    statop!((stat,j,a) -> begin stat[j,1,a] = !stat[j,1,a]; end, poly, stat, i, j)
end

"""
    setonbounds!(poly, stat, p, epos)

Set boolean value of on-bounds-status of point `p` for all areas associated with edge `epos`. 
"""
function setonbounds!(poly::PolygonMesh, stat::AbstractArray{Bool}, i::Integer, j::Integer)
    statop!((stat, j,a) -> begin stat[j,2,a] = true; end, poly, stat, i, j)
end
function statop!(f!::Function, poly::PolygonMesh{A}, stat::AbstractArray{Bool,N}, p::Integer, ed::Integer) where {A,N}
    for k in 1:max(A, 1)
        area = N == 3 ? areaindex(poly, ed, k) : 1
        if area > 0
            f!(stat, p, area)
        end
    end
end

